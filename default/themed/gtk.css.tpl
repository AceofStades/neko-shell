/* neko colors for GTK 3 and GTK 4 apps. Every color is named, so a theme that
   paints with named colors (adw-gtk3, libadwaita) follows them completely;
   other themes pick up whichever names they use. */

/* libadwaita names */
@define-color accent_color {{ accent }};
@define-color accent_bg_color {{ accent }};
@define-color accent_fg_color {{ background }};
@define-color destructive_color {{ red }};
@define-color destructive_bg_color {{ red }};
@define-color destructive_fg_color {{ background }};
@define-color success_color {{ green }};
@define-color success_bg_color {{ green }};
@define-color success_fg_color {{ background }};
@define-color warning_color {{ yellow }};
@define-color warning_bg_color {{ yellow }};
@define-color warning_fg_color {{ background }};
@define-color error_color {{ red }};
@define-color error_bg_color {{ red }};
@define-color error_fg_color {{ background }};

@define-color window_bg_color {{ dark_background }};
@define-color window_fg_color {{ foreground }};
@define-color view_bg_color {{ background }};
@define-color view_fg_color {{ foreground }};
@define-color headerbar_bg_color {{ dark_background }};
@define-color headerbar_fg_color {{ foreground }};
@define-color headerbar_border_color {{ muted }};
@define-color headerbar_backdrop_color {{ dark_background }};
@define-color headerbar_shade_color rgba(0, 0, 0, 0.36);
@define-color sidebar_bg_color {{ dark_background }};
@define-color sidebar_fg_color {{ foreground }};
@define-color sidebar_backdrop_color {{ dark_background }};
@define-color sidebar_shade_color rgba(0, 0, 0, 0.36);
@define-color card_bg_color {{ lighter_background }};
@define-color card_fg_color {{ foreground }};
@define-color card_shade_color rgba(0, 0, 0, 0.36);
@define-color dialog_bg_color {{ lighter_background }};
@define-color dialog_fg_color {{ foreground }};
@define-color popover_bg_color {{ lighter_background }};
@define-color popover_fg_color {{ foreground }};
@define-color shade_color rgba(0, 0, 0, 0.36);
@define-color scrollbar_outline_color rgba(0, 0, 0, 0.5);

/* GTK 3 names */
@define-color theme_bg_color {{ dark_background }};
@define-color theme_fg_color {{ foreground }};
@define-color theme_base_color {{ background }};
@define-color theme_text_color {{ foreground }};
@define-color theme_selected_bg_color {{ accent }};
@define-color theme_selected_fg_color {{ background }};
@define-color theme_unfocused_bg_color {{ dark_background }};
@define-color theme_unfocused_fg_color {{ foreground }};
@define-color theme_unfocused_base_color {{ background }};
@define-color theme_unfocused_text_color {{ foreground }};
@define-color theme_unfocused_selected_bg_color {{ selection }};
@define-color theme_unfocused_selected_fg_color {{ foreground }};
@define-color insensitive_bg_color {{ dark_background }};
@define-color insensitive_fg_color {{ dark_foreground }};
@define-color insensitive_base_color {{ background }};
@define-color borders {{ muted }};
@define-color unfocused_borders {{ muted }};
@define-color selected_bg_color {{ accent }};
@define-color selected_fg_color {{ background }};
