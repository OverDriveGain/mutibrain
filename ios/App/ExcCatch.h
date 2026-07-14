#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block, catching NSException — which Swift CANNOT catch — and
/// returning it as an NSError (nil = no exception). AVAudioEngine graph calls
/// (connect / start / play / scheduleBuffer) throw NSExceptions on invalid
/// state; without this every audio-graph race is an instant app crash.
FOUNDATION_EXPORT NSError * _Nullable ExcCatch(NSString *label, void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
