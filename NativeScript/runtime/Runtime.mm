#include <string>
#include <chrono>
#include "Runtime.h"
#include "Caches.h"
#include "Console.h"
#include "ArgConverter.h"
#include "Interop.h"
#include "NativeScriptException.h"
#include "InlineFunctions.h"
#include "SimpleAllocator.h"
#include "RuntimeConfig.h"
#include "Helpers.h"
#include "TSHelpers.h"
#include "WeakRef.h"
#include "Worker.h"

#define STRINGIZE(x) #x
#define STRINGIZE_VALUE_OF(x) STRINGIZE(x)

using namespace v8;
using namespace std;

#include "v8-inspector-platform.h"

namespace tns {

SimpleAllocator allocator_;

void Runtime::Initialize() {
    MetaFile::setInstance(RuntimeConfig.MetadataPtr);
}

Runtime::Runtime() {
    currentRuntime_ = this;
}

void Runtime::Init() {
    if (!mainThreadInitialized_) {
        Runtime::platform_ = RuntimeConfig.IsDebug
            ? v8_inspector::V8InspectorPlatform::CreateDefaultPlatform()
            : platform::NewDefaultPlatform().release();

        V8::InitializePlatform(Runtime::platform_);
        V8::Initialize();
        std::string flags = "--expose_gc --jitless --no-lazy";
        V8::SetFlagsFromString(flags.c_str(), flags.size());
    }

    StartupData* snapshotBlobStartupData = new StartupData();
    snapshotBlobStartupData->data = RuntimeConfig.SnapshotPtr;
    snapshotBlobStartupData->raw_size = (int)RuntimeConfig.SnapshotSize;
    V8::SetSnapshotDataBlob(snapshotBlobStartupData);

    Isolate::CreateParams create_params;
    create_params.array_buffer_allocator = &allocator_;
    Isolate* isolate = Isolate::New(create_params);

    Caches* cache = Caches::Get(isolate);
    cache->ObjectCtorInitializer = MetadataBuilder::GetOrCreateConstructorFunctionTemplate;
    cache->StructCtorInitializer = MetadataBuilder::GetOrCreateStructCtorFunction;

    HandleScope handle_scope(isolate);
    Local<FunctionTemplate> globalTemplateFunction = FunctionTemplate::New(isolate);
    globalTemplateFunction->SetClassName(tns::ToV8String(isolate, "NativeScriptGlobalObject"));
    Local<ObjectTemplate> globalTemplate = ObjectTemplate::New(isolate, globalTemplateFunction);
    DefineNativeScriptVersion(isolate, globalTemplate);

    MetadataBuilder::RegisterConstantsOnGlobalObject(isolate, globalTemplate, mainThreadInitialized_);
    Worker::Init(isolate, globalTemplate, mainThreadInitialized_);
    DefinePerformanceObject(isolate, globalTemplate);
    DefineTimeMethod(isolate, globalTemplate);
    WeakRef::Init(isolate, globalTemplate);

    isolate->SetCaptureStackTraceForUncaughtExceptions(true, 100, StackTrace::kOverview);
    isolate->AddMessageListener(NativeScriptException::OnUncaughtError);

    Local<Context> context = Context::New(isolate, nullptr, globalTemplate);
    context->Enter();

    DefineGlobalObject(context);
    DefineCollectFunction(context);
    Console::Init(isolate);
    this->moduleInternal_.Init(isolate);

    ArgConverter::Init(isolate, MetadataBuilder::StructPropertyGetterCallback, MetadataBuilder::StructPropertySetterCallback);
    Interop::RegisterInteropTypes(isolate);
    cache->ToStringFunc = MetadataBuilder::CreateToStringFunction(isolate);

    ClassBuilder::RegisterBaseTypeScriptExtendsFunction(isolate); // Register the __extends function to the global object
    ClassBuilder::RegisterNativeTypeScriptExtendsFunction(isolate); // Override the __extends function for native objects
    TSHelpers::Init(isolate);

    InlineFunctions::Init(isolate);

    mainThreadInitialized_ = true;

    isolate_ = isolate;
}

void Runtime::RunMainScript() {
    Isolate* isolate = this->GetIsolate();
    HandleScope scope(isolate);
    this->moduleInternal_.RunModule(isolate, "./");
}

void Runtime::RunScript(string file, TryCatch& tc) {
    Isolate* isolate = isolate_;
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    std::string filename = RuntimeConfig.ApplicationPath + "/" + file;
    string source = tns::ReadText(filename);
    Local<v8::String> script_source = v8::String::NewFromUtf8(isolate, source.c_str(), NewStringType::kNormal).ToLocalChecked();

    ScriptOrigin origin(tns::ToV8String(isolate, file));

    Local<Script> script;
    if (!Script::Compile(context, script_source, &origin).ToLocal(&script)) {
        return;
    }

    Local<Value> result;
    if (!script->Run(context).ToLocal(&result)) {
        return;
    }
}

void Runtime::RunModule(const std::string moduleName) {
    this->moduleInternal_.RunModule(this->isolate_, moduleName);
}

Isolate* Runtime::GetIsolate() {
    return this->isolate_;
}

const int Runtime::WorkerId() {
    return this->workerId_;
}

void Runtime::SetWorkerId(int workerId) {
    this->workerId_ = workerId;
}

void Runtime::DefineGlobalObject(Local<Context> context) {
    Local<Object> global = context->Global();
    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    if (!global->DefineOwnProperty(context, ToV8String(context->GetIsolate(), "global"), global, readOnlyFlags).FromMaybe(false)) {
        assert(false);
    }

    if (mainThreadInitialized_ && !global->DefineOwnProperty(context, ToV8String(context->GetIsolate(), "self"), global, readOnlyFlags).FromMaybe(false)) {
        assert(false);
    }
}

void Runtime::DefineCollectFunction(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    Local<Object> global = context->Global();
    Local<Value> value;
    bool success = global->Get(context, tns::ToV8String(isolate, "gc")).ToLocal(&value);
    assert(success);

    if (value.IsEmpty() || !value->IsFunction()) {
        return;
    }

    Local<v8::Function> gcFunc = value.As<v8::Function>();
    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    success = global->DefineOwnProperty(context, tns::ToV8String(isolate, "__collect"), gcFunc, readOnlyFlags).FromMaybe(false);
    assert(success);
}

void Runtime::DefinePerformanceObject(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
    Local<ObjectTemplate> performanceTemplate = ObjectTemplate::New(isolate);

    Local<FunctionTemplate> nowFuncTemplate = FunctionTemplate::New(isolate, PerformanceNowCallback);
    performanceTemplate->Set(tns::ToV8String(isolate, "now"), nowFuncTemplate);

    Local<v8::String> performancePropertyName = ToV8String(isolate, "performance");
    globalTemplate->Set(performancePropertyName, performanceTemplate);
}

void Runtime::PerformanceNowCallback(const FunctionCallbackInfo<Value>& args) {
    std::chrono::system_clock::time_point now = std::chrono::system_clock::now();
    std::chrono::milliseconds timestampMs = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch());
    double result = timestampMs.count();
    args.GetReturnValue().Set(result);
}

void Runtime::DefineNativeScriptVersion(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    globalTemplate->Set(ToV8String(isolate, "__runtimeVersion"), ToV8String(isolate, STRINGIZE_VALUE_OF(NATIVESCRIPT_VERSION)), readOnlyFlags);
}

void Runtime::DefineTimeMethod(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate) {
    Local<FunctionTemplate> timeFunctionTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        auto nano = std::chrono::time_point_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now());
        double duration = nano.time_since_epoch().count() / 1000000.0;
        info.GetReturnValue().Set(duration);
    });
    globalTemplate->Set(ToV8String(isolate, "__time"), timeFunctionTemplate);
}

Platform* Runtime::platform_ = nullptr;
bool Runtime::mainThreadInitialized_ = false;
thread_local Runtime* Runtime::currentRuntime_ = nullptr;

}
