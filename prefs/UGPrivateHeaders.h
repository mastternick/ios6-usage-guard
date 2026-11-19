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
 * Cell types used by a Preferences table. These are the values of the
 * PSCellType enum in the host's PSTableCell.h on iOS 6; the numbers, not the
 * names, are what the host compares against. Choosing the wrong constant
 * yields a cell that draws the wrong control (a slider instead of a value, an
 * edit field instead of static text), so the full enum is spelled out here.
 */
enum {
    PSGroupCell = 0,
    PSLinkCell = 1,
    PSLinkListCell = 2,
    PSListItemCell = 3,
    PSTitleValueCell = 4,
    PSSliderCell = 5,
    PSSwitchCell = 6,
    PSStaticTextCell = 7,
    PSEditTextCell = 8,
    PSSegmentCell = 9,
    PSGiantIconCell = 10,
    PSGiantCell = 11,
    PSSecureEditTextCell = 12,
    PSButtonCell = 13
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
 *
 * `_specifiers` is the host's own storage for the rows it renders: since iOS 4
 * Preferences builds its groups from this ivar, so a subclass must publish the
 * list there, not merely return it from -specifiers. The ivar is declared here
 * only so the compiler knows its type; the non-fragile ABI resolves the access
 * to _OBJC_IVAR_$_PSListController._specifiers against the real Preferences
 * class when the bundle is loaded (-Wl,-undefined,dynamic_lookup). PSListController
 * is not linked, so this declaration must match the host's layout by name.
 */
@interface PSListController : PSViewController {
    NSArray *_specifiers;
}
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (void)reload;
@end

#endif /* UG_PRIVATE_HEADERS_H */
