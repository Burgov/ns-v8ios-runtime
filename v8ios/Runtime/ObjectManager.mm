#include <Foundation/Foundation.h>
#include "ObjectManager.h"
#include "MetadataBuilder.h"
#include "DataWrapper.h"

using namespace v8;
using namespace std;

namespace tns {

Persistent<Object>* ObjectManager::Register(Isolate* isolate, const v8::Local<v8::Object> obj) {
    Persistent<Object>* objectHandle = new Persistent<Object>(isolate, obj);
    ObjectWeakCallbackState* state = new ObjectWeakCallbackState(objectHandle);
    objectHandle->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
    return objectHandle;
}

void ObjectManager::FinalizerCallback(const WeakCallbackInfo<ObjectWeakCallbackState>& data) {
    ObjectWeakCallbackState* state = data.GetParameter();
    Isolate* isolate = data.GetIsolate();
    Local<Object> obj = state->target_->Get(isolate);
    if (obj->InternalFieldCount() > 0) {
        Local<External> ext = obj->GetInternalField(0).As<External>();
        BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
        if (wrapper->Type() == WrapperType::Primitive) {
            PrimitiveDataWrapper* primitiveWrapper = static_cast<PrimitiveDataWrapper*>(ext->Value());
            delete primitiveWrapper;
        } else {
            ObjCDataWrapper* objCObjectWrapper = static_cast<ObjCDataWrapper*>(ext->Value());
            if (objCObjectWrapper->Data() != nil) {
                auto it = Caches::Instances.find(objCObjectWrapper->Data());
                if (it != Caches::Instances.end()) {
                    it->second->Reset();
                    delete it->second;
                    Caches::Instances.erase(it);
                }
            }
            delete objCObjectWrapper;
        }
        obj->SetInternalField(0, v8::Undefined(isolate));
    }
    state->target_->Reset();
    delete state->target_;
    delete state;
}

}
