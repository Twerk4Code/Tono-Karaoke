#import "TorchModule.h"
#include <torch/script.h>

// The local libtorch dylibs in this workspace do not ship the Python-refcount
// hooks declared by the newer headers we recovered from the local PyTorch install.
// Tono uses TorchScript inference only, so no-op weak definitions are sufficient.
namespace c10 {
__attribute__((weak)) void TensorImpl::incref_pyobject() const noexcept {}
__attribute__((weak)) void TensorImpl::decref_pyobject() const noexcept {}
__attribute__((weak)) bool TensorImpl::try_incref_pyobject() const noexcept { return true; }

__attribute__((weak)) void StorageImpl::incref_pyobject() const noexcept {}
__attribute__((weak)) void StorageImpl::decref_pyobject() const noexcept {}
__attribute__((weak)) bool StorageImpl::try_incref_pyobject() const noexcept { return true; }
} // namespace c10

@implementation TorchModule {
@protected
    torch::jit::script::Module _impl;
}

- (nullable instancetype)initWithFileAtPath:(NSString *)filePath {
    self = [super init];
    if (self) {
        try {
            _impl = torch::jit::load(filePath.UTF8String);
            _impl.eval();
        } catch (const std::exception &exception) {
            NSLog(@"[TorchModule] Error loading model: %s", exception.what());
            return nil;
        }
    }
    return self;
}

- (BOOL)predictWithLeftChannel:(const float *)inputL
                  rightChannel:(const float *)inputR
                        length:(int)length
                    outputLeft:(float *)outputL
                   outputRight:(float *)outputR {
    try {
        torch::NoGradGuard no_grad;

        // Build input tensor [1, 2, length] from separate L/R channel pointers.
        at::Tensor input = torch::empty({1, 2, length}, at::kFloat);
        float *ch0 = input.data_ptr<float>();
        float *ch1 = ch0 + length;
        memcpy(ch0, inputL, length * sizeof(float));
        memcpy(ch1, inputR, length * sizeof(float));

        // Forward pass — model returns [1, 2, length] vocal estimate
        std::vector<torch::jit::IValue> inputs;
        inputs.push_back(input);
        at::Tensor output = _impl.forward(inputs).toTensor();

        // Copy output channels back to caller buffers
        const float *outCh0 = output.data_ptr<float>();
        const float *outCh1 = outCh0 + length;
        memcpy(outputL, outCh0, length * sizeof(float));
        memcpy(outputR, outCh1, length * sizeof(float));

        return YES;
    } catch (const std::exception &exception) {
        NSLog(@"[TorchModule] Inference error: %s", exception.what());
        return NO;
    }
}

@end
