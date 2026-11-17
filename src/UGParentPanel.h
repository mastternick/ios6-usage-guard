#import <UIKit/UIKit.h>

#import "UGGuardCore.h"

@class UGParentPanelController;

/*
 * The panel owns a copy of the cycle state, mutates it through the core, and
 * hands the result back to the runtime, which persists it and syncs the UI.
 * PIN verification/storage and lockout accounting stay in UGPrefs.
 */
@protocol UGParentPanelDelegate <NSObject>

- (UGState)panelCurrentState;
- (BOOL)panelVerifyPIN:(NSString *)pin;
- (BOOL)panelStorePIN:(NSString *)pin;
- (NSInteger)panelPINLockoutSeconds;
- (void)panelApplyState:(UGState)state;
- (void)panelRequestDismiss;

@end

@interface UGParentPanelController : UIViewController

@property (nonatomic, weak) id<UGParentPanelDelegate> delegate;

/* requiresSetup == YES starts on the mandatory first-run PIN wizard. */
- (id)initWithDelegate:(id<UGParentPanelDelegate>)delegate
         requiresSetup:(BOOL)requiresSetup;

/* Pushed by the runtime every second while the panel is on screen. */
- (void)updateState:(UGState)state;

@end
