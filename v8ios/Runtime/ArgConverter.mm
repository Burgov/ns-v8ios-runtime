#include <Foundation/Foundation.h>
#include "ArgConverter.h"
#include "ObjectManager.h"
#include "Caches.h"
#include "Interop.h"

using namespace v8;
using namespace std;

namespace tns {

void ArgConverter::Init(Isolate* isolate, GenericNamedPropertyGetterCallback structPropertyGetter, GenericNamedPropertySetterCallback structPropertySetter) {
    poEmptyObjCtorFunc_ = new Persistent<v8::Function>(isolate, ArgConverter::CreateEmptyInstanceFunction(isolate));
    poEmptyStructCtorFunc_ = new Persistent<v8::Function>(isolate, ArgConverter::CreateEmptyInstanceFunction(isolate, structPropertyGetter, structPropertySetter));
}

Local<Value> ArgConverter::Invoke(Isolate* isolate, Class klass, Local<Object> receiver, const std::vector<Local<Value>> args, const MethodMeta* meta, bool isMethodCallback) {
    id target = nil;
    bool instanceMethod = !receiver.IsEmpty();
    bool callSuper = false;
    if (instanceMethod) {
        Local<External> ext = receiver->GetInternalField(0).As<External>();
        // TODO: Check the actual type of the DataWrapper
        ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());
        target = wrapper->Data();

        std::string className = object_getClassName(target);
        auto it = Caches::ClassPrototypes.find(className);
        // For extended classes we will call the base method
        callSuper = isMethodCallback && it != Caches::ClassPrototypes.end();
    }

    return Interop::CallFunction(isolate, meta, target, klass, args, callSuper);
}

Local<Value> ArgConverter::ConvertArgument(Isolate* isolate, BaseDataWrapper* wrapper) {
    // TODO: Check the actual DataWrapper type
    if (wrapper == nullptr) {
        return Null(isolate);
    }

    Local<Value> result = CreateJsWrapper(isolate, wrapper, Local<Object>());
    return result;
}

void ArgConverter::MethodCallback(ffi_cif* cif, void* retValue, void** argValues, void* userData) {
    void (^cb)() = ^{
        MethodCallbackWrapper* data = static_cast<MethodCallbackWrapper*>(userData);

        Isolate* isolate = data->isolate_;

        HandleScope handle_scope(isolate);

        Persistent<Object>* poCallback = data->callback_;
        ObjectWeakCallbackState* weakCallbackState = new ObjectWeakCallbackState(poCallback);
        poCallback->SetWeak(weakCallbackState, ObjectManager::FinalizerCallback, WeakCallbackType::kFinalizer);

        Local<v8::Function> callback = poCallback->Get(isolate).As<v8::Function>();

        std::vector<Local<Value>> v8Args;
        const TypeEncoding* typeEncoding = data->typeEncoding_;
        for (int i = 0; i < data->paramsCount_; i++) {
            typeEncoding = typeEncoding->next();
            int argIndex = i + data->initialParamIndex_;

            Local<Value> jsWrapper;
            if (typeEncoding->type == BinaryTypeEncodingType::LongEncoding) {
                long arg = *static_cast<long*>(argValues[argIndex]);
                jsWrapper = Number::New(isolate, arg);
            } else if (typeEncoding->type == BinaryTypeEncodingType::BoolEncoding) {
                bool arg = *static_cast<bool*>(argValues[argIndex]);
                jsWrapper = v8::Boolean::New(isolate, arg);
            } else {
                const id arg = *static_cast<const id*>(argValues[argIndex]);
                if (arg != nil) {
                    BaseDataWrapper* wrapper = new ObjCDataWrapper(nullptr, arg);
                    jsWrapper = ArgConverter::ConvertArgument(isolate, wrapper);
                } else {
                    jsWrapper = Null(data->isolate_);
                }
            }

            v8Args.push_back(jsWrapper);
        }

        Local<Context> context = isolate->GetCurrentContext();
        Local<Object> thiz = context->Global();
        if (data->initialParamIndex_ > 0) {
            id self_ = *static_cast<const id*>(argValues[0]);
            auto it = Caches::Instances.find(self_);
            if (it != Caches::Instances.end()) {
                thiz = it->second->Get(data->isolate_);
            } else {
                ObjCDataWrapper* wrapper = new ObjCDataWrapper(nullptr, self_);
                thiz = ArgConverter::CreateJsWrapper(isolate, wrapper, Local<Object>()).As<Object>();

                std::string className = object_getClassName(self_);
                auto it = Caches::ClassPrototypes.find(className);
                if (it != Caches::ClassPrototypes.end()) {
                    Local<Context> context = isolate->GetCurrentContext();
                    thiz->SetPrototype(context, it->second->Get(isolate)).ToChecked();
                }

                //TODO: We are creating a persistent object here that will never be GCed
                // We need to determine the lifetime of this object
                Persistent<Object>* poObj = new Persistent<Object>(data->isolate_, thiz);
                Caches::Instances.insert(std::make_pair(self_, poObj));
            }
        }

        Local<Value> result;
        if (!callback->Call(context, thiz, (int)v8Args.size(), v8Args.data()).ToLocal(&result)) {
            assert(false);
        }

        if (!result.IsEmpty() && !result->IsUndefined()) {
            if (result->IsNumber() || result->IsNumberObject()) {
                if (data->typeEncoding_->type == BinaryTypeEncodingType::LongEncoding) {
                    long value = result.As<Number>()->Value();
                    *static_cast<long*>(retValue) = value;
                    return;
                } else if (data->typeEncoding_->type == BinaryTypeEncodingType::DoubleEncoding) {
                    double value = result.As<Number>()->Value();
                    *static_cast<double*>(retValue) = value;
                    return;
                }
            } else if (result->IsObject()) {
                if (data->typeEncoding_->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
                    Local<External> ext = result.As<Object>()->GetInternalField(0).As<External>();
                    ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());
                    id data = wrapper->Data();
                    *(ffi_arg *)retValue = (unsigned long)data;
                    return;
                }
            }

            // TODO: Handle other return types, i.e. assign the retValue parameter from the v8 result
            assert(false);
        }
    };

    if ([NSThread isMainThread]) {
        cb();
    } else {
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_main_queue(), ^{
            cb();
            dispatch_group_leave(group);
        });

        if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
            assert(false);
        }
    }
}

Local<Value> ArgConverter::CreateJsWrapper(Isolate* isolate, BaseDataWrapper* wrapper, Local<Object> receiver) {
    Local<Context> context = isolate->GetCurrentContext();

    if (wrapper == nullptr) {
        return Null(isolate);
    }

    if (wrapper->Type() == WrapperType::Record) {
        if (receiver.IsEmpty()) {
            receiver = CreateEmptyStruct(context);
        }

        Local<External> ext = External::New(isolate, wrapper);
        receiver->SetInternalField(0, ext);

        return receiver;
    }

    id target = nil;
    if (wrapper->Type() == WrapperType::ObjCObject) {
        ObjCDataWrapper* dataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
        target = dataWrapper->Data();
    }

    if (target == nil) {
        return Null(isolate);
    }

   if (receiver.IsEmpty()) {
       auto it = Caches::Instances.find(target);
       if (it != Caches::Instances.end()) {
           receiver = it->second->Get(isolate);
       } else {
           receiver = CreateEmptyObject(context);
           Caches::Instances.insert(std::make_pair(target, new Persistent<Object>(isolate, receiver)));
       }
   }

    Class klass = [target class];
    const BaseClassMeta* meta = FindInterfaceMeta(klass);
    if (meta != nullptr) {
        std::string className = object_getClassName(target);
        auto it = Caches::ClassPrototypes.find(className);
        if (it != Caches::ClassPrototypes.end()) {
            Local<Value> prototype = it->second->Get(isolate);
            bool success;
            if (!receiver->SetPrototype(context, prototype).To(&success) || !success) {
                assert(false);
            }
        } else {
            auto it = Caches::Prototypes.find(meta);
            if (it != Caches::Prototypes.end()) {
                Local<Value> prototype = it->second->Get(isolate);
                bool success;
                if (!receiver->SetPrototype(context, prototype).To(&success) || !success) {
                    assert(false);
                }
            }
        }
    }

    Local<External> ext = External::New(isolate, wrapper);
    receiver->SetInternalField(0, ext);

    return receiver;
}

const BaseClassMeta* ArgConverter::FindInterfaceMeta(Class klass) {
    std::string origClassName = class_getName(klass);
    auto it = Caches::Metadata.find(origClassName);
    if (it != Caches::Metadata.end()) {
        return it->second;
    }

    std::string className = origClassName;

    while (true) {
        const BaseClassMeta* result = GetInterfaceMeta(className);
        if (result != nullptr) {
            Caches::Metadata.insert(std::make_pair(origClassName, result));
            return result;
        }

        klass = class_getSuperclass(klass);
        if (klass == nullptr) {
            break;
        }

        className = class_getName(klass);
    }

    return nullptr;
}

const BaseClassMeta* ArgConverter::GetInterfaceMeta(std::string name) {
    auto it = Caches::Metadata.find(name);
    if (it != Caches::Metadata.end()) {
        return it->second;
    }

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    const Meta* result = globalTable->findMeta(name.c_str());

    if (result == nullptr) {
        return nullptr;
    }

    if (result->type() == MetaType::Interface) {
        return static_cast<const InterfaceMeta*>(result);
    } else if (result->type() == MetaType::ProtocolType) {
        return static_cast<const ProtocolMeta*>(result);
    }

    assert(false);
}

Local<Object> ArgConverter::CreateEmptyObject(Local<Context> context) {
    return ArgConverter::CreateEmptyInstance(context, poEmptyObjCtorFunc_);
}

Local<Object> ArgConverter::CreateEmptyStruct(Local<Context> context) {
    return ArgConverter::CreateEmptyInstance(context, poEmptyStructCtorFunc_);
}

Local<Object> ArgConverter::CreateEmptyInstance(Local<Context> context, Persistent<v8::Function>* ctorFunc) {
    Isolate* isolate = context->GetIsolate();
    Local<v8::Function> emptyCtorFunc = ctorFunc->Get(isolate);
    Local<Value> value;
    if (!emptyCtorFunc->CallAsConstructor(context, 0, nullptr).ToLocal(&value) || value.IsEmpty() || !value->IsObject()) {
        assert(false);
    }
    Local<Object> result = value.As<Object>();
    return result;
}

Local<v8::Function> ArgConverter::CreateEmptyInstanceFunction(Isolate* isolate, GenericNamedPropertyGetterCallback propertyGetter, GenericNamedPropertySetterCallback propertySetter) {
    Local<FunctionTemplate> emptyInstanceCtorFuncTemplate = FunctionTemplate::New(isolate, nullptr);
    Local<ObjectTemplate> instanceTemplate = emptyInstanceCtorFuncTemplate->InstanceTemplate();
    instanceTemplate->SetInternalFieldCount(1);

    NamedPropertyHandlerConfiguration config(propertyGetter, propertySetter);
    instanceTemplate->SetHandler(config);

    Local<v8::Function> emptyInstanceCtorFunc;
    if (!emptyInstanceCtorFuncTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&emptyInstanceCtorFunc)) {
        assert(false);
    }
    return emptyInstanceCtorFunc;
}

Persistent<v8::Function>* ArgConverter::poEmptyObjCtorFunc_;
Persistent<v8::Function>* ArgConverter::poEmptyStructCtorFunc_;

}
