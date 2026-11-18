#import <UIKit/UIKit.h>

/*
 * Minimal declaration of the Preferences framework's detail-controller base
 * class. The framework is not linked: the bundle is built with
 * -Wl,-undefined,dynamic_lookup, so these selectors bind to the host
 * Preferences.app's PSViewController when the pane loads.
 *
 * Only the API Preferences calls on a detail controller is declared here.
 */

#ifndef UG_PRIVATE_HEADERS_H
#define UG_PRIVATE_HEADERS_H

@interface PSViewController : UIViewController
- (id)initForContentSize:(CGSize)size;
- (void)setRootController:(id)controller;
- (void)setParentController:(id)controller;
- (id)parentController;
- (id)rootController;
- (void)setSpecifier:(id)specifier;
- (id)specifier;
@end

#endif /* UG_PRIVATE_HEADERS_H */
