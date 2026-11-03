#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift can't catch NSException, and PhotoKit throws one for an unsupported fetch predicate key.
FOUNDATION_EXPORT NSString *_Nullable SpikeCatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
