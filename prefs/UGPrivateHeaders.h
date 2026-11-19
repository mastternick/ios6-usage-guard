#import <UIKit/UIKit.h>

/*
 * Minimal declarations of the Preferences framework objects this bundle uses.
 * The framework is not linked: the bundle is built with
 * -Wl,-undefined,dynamic_lookup, so these selectors bind to the host
 * Preferences.app's own classes when the pane loads.
 *
 * Only the API the pane is allowed to rely on is declared here: the
 * detail-controller base class, the list controller built on it, and the
 * specifier object the host uses to describe every row.
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

/*
 * Cell types used by a Preferences table. These are the values the host's
 * PSTableCell implementation compares against on iOS 6; the names come from
 * Apple's own specifier plists. Choosing the wrong constant yields a cell that
 * draws nothing useful, so they are spelled out rather than inlined.
 */
enum {
    PSGroupCell = 0,
    PSLinkCell = 1,
    PSButtonCell = 2,
    PSLinkListCell = 3,
    PSTitleValueCell = 5,
    PSSwitchCell = 6,
    PSStaticTextCell = 8
};

/*
 * One row. The factory is the only constructor used by the pane: it carries
 * the label, the target that owns the get/set/button selectors and the cell
 * type. `set:` selectors are invoked as (id)value specifier:(PSSpecifier *)spec,
 * get selectors as specifier:(PSSpecifier *)spec, and button actions with no
 * arguments at all.
 */
@interface PSSpecifier : NSObject
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get
                        detail:(Class)detail cell:(int)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setButtonAction:(SEL)action;
- (void)setTarget:(id)target;
- (void)setCellType:(int)cellType;
- (void)setName:(NSString *)name;
@end

/*
 * The host's specifier-driven table controller. Its own view/table machinery
 * renders and reloads the rows, so the pane no longer builds a UITableView by
 * hand.
 */
@interface PSListController : PSViewController
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (void)reload;
@end

#endif /* UG_PRIVATE_HEADERS_H */
