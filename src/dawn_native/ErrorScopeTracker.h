// Copyright 2019 The Dawn Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef DAWNNATIVE_ERRORSCOPETRACKER_H_
#define DAWNNATIVE_ERRORSCOPETRACKER_H_

#include "common/RefCounted.h"
#include "common/SerialQueue.h"
#include "dawn_native/IntegerTypes.h"

namespace dawn_native {

    class DeviceBase;
    class ErrorScope;

    class ErrorScopeTracker {
      public:
        ErrorScopeTracker(DeviceBase* device);
        ~ErrorScopeTracker();

        void TrackUntilLastSubmitComplete(ErrorScope* scope);

        void Tick(ExecutionSerial completedSerial);

      protected:
        DeviceBase* mDevice;
        SerialQueue<ExecutionSerial, Ref<ErrorScope>> mScopesInFlight;
    };

}  // namespace dawn_native

#endif  // DAWNNATIVE_ERRORSCOPETRACKER_H_
