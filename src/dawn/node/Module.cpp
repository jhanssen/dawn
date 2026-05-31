// Copyright 2021 The Dawn & Tint Authors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include <filesystem>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "dawn/dawn_proc.h"
#include "dawn/wire/WireClient.h"
#include "dawn/webgpu_cpp.h"
#include "src/dawn/node/binding/AsyncRunner.h"
#include "src/dawn/node/binding/Flags.h"
#include "src/dawn/node/binding/GPU.h"
#include "src/dawn/node/binding/GPUDevice.h"
#include "src/dawn/node/binding/GPUTexture.h"
#include "src/dawn/node/interop/Core.h"
#include "src/dawn/node/interop/WebGPU.h"

#ifdef DAWN_EMIT_COVERAGE
extern "C" {
void __llvm_profile_reset_counters(void);
void __llvm_profile_set_filename(const char*);
int __llvm_profile_write_file(void);
}
#endif  // DAWN_EMIT_COVERAGE

namespace {

Napi::Value CreateGPU(const Napi::CallbackInfo& info) {
    const auto& env = info.Env();

    std::tuple<std::vector<std::string>> args;
    if (auto res = wgpu::interop::FromJS(info, args); !res) {
        Napi::Error::New(env, res.error).ThrowAsJavaScriptException();
        return env.Undefined();
    }

    wgpu::binding::Flags flags;

    // Parse out the key=value flags out of the input args array
    for (const auto& arg : std::get<0>(args)) {
        const size_t sep_index = arg.find("=");
        if (sep_index == std::string::npos) {
            Napi::Error::New(env, "Flags expected argument format is <key>=<value>")
                .ThrowAsJavaScriptException();
            return env.Undefined();
        }
        flags.Set(arg.substr(0, sep_index), arg.substr(sep_index + 1));
    }

    // Construct a wgpu::interop::GPU interface, implemented by wgpu::bindings::GPU.
    return wgpu::interop::GPU::Create<wgpu::binding::GPU>(env, std::move(flags));
}

// wrapDevice(instanceHandle: bigint, deviceHandle: bigint) -> GPUDevice
//
// Wraps an already-created wire-client wgpu::Instance + wgpu::Device (handles
// brought up by the host application over the Dawn wire) into a standard
// dawn.node GPUDevice JS object. The proc table is the wire-client table (set in
// Initialize), so all WebGPU calls on the returned device dispatch over the wire
// to the GPU process. The host application owns the connection + wire pump; this
// binding only issues commands.
Napi::Value WrapDevice(const Napi::CallbackInfo& info) {
    const auto& env = info.Env();
    if (info.Length() < 2 || !info[0].IsBigInt() || !info[1].IsBigInt()) {
        Napi::Error::New(env, "wrapDevice(instanceHandle: bigint, deviceHandle: bigint)")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }
    bool lossless = false;
    uint64_t instPtr = info[0].As<Napi::BigInt>().Uint64Value(&lossless);
    uint64_t devPtr = info[1].As<Napi::BigInt>().Uint64Value(&lossless);

    // Adopt one ref for each handle (the host keeps its own).
    WGPUInstance rawInst = reinterpret_cast<WGPUInstance>(instPtr);
    WGPUDevice rawDev = reinterpret_cast<WGPUDevice>(devPtr);
    wgpuInstanceAddRef(rawInst);
    wgpuDeviceAddRef(rawDev);
    wgpu::Instance instance = wgpu::Instance::Acquire(rawInst);
    wgpu::Device device = wgpu::Device::Acquire(rawDev);

    auto async = wgpu::binding::AsyncRunner::Create(instance);

    // The device was created by the host; we cannot install a device-lost
    // callback after the fact. The lost promise stays pending (Discarded on
    // GPUDevice destruction).
    using LostInfo = wgpu::interop::Interface<wgpu::interop::GPUDeviceLostInfo>;
    wgpu::interop::Promise<LostInfo> lost_promise(env, PROMISE_INFO);

    wgpu::DeviceDescriptor desc{};
    auto gpu_device =
        std::make_unique<wgpu::binding::GPUDevice>(env, desc, device, lost_promise, async);
    gpu_device->SetBorrowed();  // host owns the device; don't Destroy() on GC.
    return wgpu::interop::GPUDevice::Bind(env, std::move(gpu_device));
}

// wrapTexture(deviceHandle: bigint, textureHandle: bigint) -> GPUTexture
//
// Wraps an already-created wire-client wgpu::Texture (e.g. a dmabuf-backed
// texture the host imported + injected server-side) into a dawn.node GPUTexture,
// so JS can sample it (createView, bind groups). The host owns the texture's
// lifetime; this wrapper only references it. Width/height/format are queried
// from the texture over the wire, so the descriptor here is minimal.
Napi::Value WrapTexture(const Napi::CallbackInfo& info) {
    const auto& env = info.Env();
    if (info.Length() < 2 || !info[0].IsBigInt() || !info[1].IsBigInt()) {
        Napi::Error::New(env, "wrapTexture(deviceHandle: bigint, textureHandle: bigint)")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }
    bool lossless = false;
    uint64_t devPtr = info[0].As<Napi::BigInt>().Uint64Value(&lossless);
    uint64_t texPtr = info[1].As<Napi::BigInt>().Uint64Value(&lossless);

    WGPUDevice rawDev = reinterpret_cast<WGPUDevice>(devPtr);
    WGPUTexture rawTex = reinterpret_cast<WGPUTexture>(texPtr);
    wgpuDeviceAddRef(rawDev);
    wgpuTextureAddRef(rawTex);
    wgpu::Device device = wgpu::Device::Acquire(rawDev);
    wgpu::Texture texture = wgpu::Texture::Acquire(rawTex);

    wgpu::TextureDescriptor desc{};
    auto gpu_texture = std::make_unique<wgpu::binding::GPUTexture>(device, desc, texture);
    return wgpu::interop::GPUTexture::Bind(env, std::move(gpu_texture));
}

#ifdef DAWN_EMIT_COVERAGE
struct Coverage {
    Coverage() : output_path_{GetOutputPath()} {
        __llvm_profile_set_filename(output_path_.string().c_str());
    }
    ~Coverage() { std::filesystem::remove(output_path_); }

    static void Begin(const Napi::CallbackInfo& info) {
        auto* coverage = static_cast<Coverage*>(info.Data());
        std::filesystem::remove(coverage->output_path_);
        __llvm_profile_reset_counters();
    }

    static Napi::Value End(const Napi::CallbackInfo& info) {
        __llvm_profile_write_file();
        auto* coverage = static_cast<Coverage*>(info.Data());
        return Napi::String::New(info.Env(), coverage->output_path_.string().c_str());
    }

  private:
    static std::filesystem::path GetOutputPath() { return std::tmpnam(nullptr); }

    std::filesystem::path output_path_;
};
#endif  // DAWN_EMIT_COVERAGE

}  // namespace

// Initialize() initializes the Dawn node module, registering all the WebGPU
// types into the global object, and adding the 'create' function on the exported
// object.
NAPI_MODULE_EXPORT Napi::Object Initialize(Napi::Env env, Napi::Object exports) {
    // Set all the Dawn procedure function pointers to the WIRE CLIENT table.
    // This dawn.node variant drives WebGPU over the Dawn wire to a separate GPU
    // process; it does not run native Dawn in-process. The host application's
    // wire client shares this same process-global proc table.
    dawnProcSetProcs(&dawn::wire::client::GetProcs());

    // Register all the interop types
    exports.Set(Napi::String::New(env, "globals"), wgpu::interop::Initialize(env));

    // Export function that creates and returns the wgpu::interop::GPU interface
    exports.Set(Napi::String::New(env, "create"), Napi::Function::New<CreateGPU>(env));

    // Wrap a host-provided wire instance+device into a GPUDevice (wire variant).
    exports.Set(Napi::String::New(env, "wrapDevice"), Napi::Function::New<WrapDevice>(env));
    // Wrap a host-provided wire texture into a GPUTexture (e.g. dmabuf-backed).
    exports.Set(Napi::String::New(env, "wrapTexture"), Napi::Function::New<WrapTexture>(env));

#ifdef DAWN_EMIT_COVERAGE
    Coverage* coverage = new Coverage();
    auto coverage_provider = Napi::Object::New(env);
    coverage_provider.Set("begin", Napi::Function::New(env, &Coverage::Begin, nullptr, coverage));
    coverage_provider.Set("end", Napi::Function::New(env, &Coverage::End, nullptr, coverage));
    coverage_provider.AddFinalizer([](const Napi::Env&, Coverage* c) { delete c; }, coverage);
    exports.Set(Napi::String::New(env, "coverage"), coverage_provider);
#endif  // DAWN_EMIT_COVERAGE

    return exports;
}

NODE_API_MODULE(addon, Initialize)
