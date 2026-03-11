#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C wrapper around libtorch for loading TorchScript models.
/// Swift communicates with this class via the bridging header.
@interface TorchModule : NSObject

/// Load a TorchScript model from a file path.
/// @param filePath Absolute path to the .pt file.
/// @return An initialized TorchModule, or nil on failure.
- (nullable instancetype)initWithFileAtPath:(NSString *)filePath
    NS_SWIFT_NAME(init(fileAtPath:));

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/// Run end-to-end vocal separation inference.
/// @param inputL  Left channel float samples (chunkSize elements).
/// @param inputR  Right channel float samples (chunkSize elements).
/// @param length  Number of samples per channel (must equal model chunk size = 352800).
/// @param outputL Caller-allocated buffer for output left channel (length elements).
/// @param outputR Caller-allocated buffer for output right channel (length elements).
/// @return YES on success, NO on failure.
- (BOOL)predictWithLeftChannel:(const float *)inputL
                  rightChannel:(const float *)inputR
                        length:(int)length
                    outputLeft:(float *)outputL
                   outputRight:(float *)outputR
    NS_SWIFT_NAME(predict(left:right:length:outputLeft:outputRight:));

@end

NS_ASSUME_NONNULL_END
