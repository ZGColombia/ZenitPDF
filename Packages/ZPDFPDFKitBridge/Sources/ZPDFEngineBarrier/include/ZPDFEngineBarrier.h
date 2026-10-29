#ifndef ZPDF_ENGINE_BARRIER_H
#define ZPDF_ENGINE_BARRIER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// An Objective-C exception that was raised inside a framework call and caught at the
/// barrier, reduced to two strings so it can cross into Swift as a value.
NS_SWIFT_SENDABLE
@interface ZPDFRaisedException : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *reason;
- (instancetype)initWithName:(NSString *)name reason:(NSString *)reason NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Runs `block` inside `@try`/`@catch`.
///
/// Swift cannot catch an Objective-C exception: `NSException` unwinds past Swift frames
/// and terminates the process. PDFKit raises from inside `-[PDFDocument
/// documentAttributes]`, and therefore from every code path that builds a page layout,
/// when a malformed `/Info` dictionary yields a key it cannot map. A PDF is hostile data,
/// so every call into PDFKit that touches document-supplied structure goes through here.
///
/// Returns `nil` when `block` returned normally, and the caught exception otherwise.
extern ZPDFRaisedException * _Nullable ZPDFRunCatchingObjCException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END

#endif /* ZPDF_ENGINE_BARRIER_H */
