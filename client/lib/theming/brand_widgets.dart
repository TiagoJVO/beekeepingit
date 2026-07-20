import 'package:flutter/material.dart';

import '../core/widgets/tap_target.dart';
import 'app_theme.dart';
import 'brand_dimens.dart';
import 'brand_theme.dart';

/// The shared building blocks that give every screen the prototype's look
/// (FR-UX-1, D-18, EPIC-11) — an uppercase section [Eyebrow], a Playfair
/// [SectionHeader], the label-above-field [LabeledField], the plum [HeroCard],
/// the white [BrandRowCard], the sand [NotesCard], an [EmptyState], a
/// selectable [BrandChip], and the divided [MenuListCard]. Screens compose
/// these rather than re-deriving paddings/radii/colours inline, so the visual
/// language lives in one place and future screens inherit it by construction.

/// A gold, letter-spaced, uppercase section eyebrow (e.g. "ORDERED BY
/// PROXIMITY", "STEP 1 OF 2").
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {this.color, super.key});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontFamily: AppTheme.bodyFontFamily,
        fontWeight: FontWeight.w600,
        fontSize: 12,
        letterSpacing: 1.6,
        color: color ?? context.brand.eyebrow,
      ),
    );
  }
}

/// A Playfair section header (the 19px serif titles between content blocks).
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {this.padding, super.key});

  final String text;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final child = Text(
      text,
      style: TextStyle(
        fontFamily: AppTheme.displayFontFamily,
        fontWeight: FontWeight.w600,
        fontSize: 19,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
    return padding == null ? child : Padding(padding: padding!, child: child);
  }
}

/// A form field with its label sitting *above* it (the prototype's field
/// pattern) rather than a floating Material label.
class LabeledField extends StatelessWidget {
  const LabeledField({required this.label, required this.child, super.key});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 2),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: AppTheme.bodyFontFamily,
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// The plum hero card that heads detail/settings screens (radius 20, white
/// foreground). [padding] defaults to the hero padding.
class HeroCard extends StatelessWidget {
  const HeroCard({required this.child, this.padding, super.key});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(BrandDimens.padHero),
      decoration: BoxDecoration(
        color: context.brand.heroSurface,
        borderRadius: BrandDimens.borderHero,
      ),
      child: child,
    );
  }
}

/// A rounded leading icon tile (the sand/tinted square behind a row's icon).
class LeadingIconTile extends StatelessWidget {
  const LeadingIconTile({
    required this.icon,
    required this.color,
    required this.tint,
    this.size = BrandDimens.sizeLeadingTile,
    super.key,
  });

  final IconData icon;
  final Color color;
  final Color tint;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BrandDimens.borderTile,
      ),
      child: Icon(icon, color: color, size: size * 0.54),
    );
  }
}

/// A white content card on the 1px hairline. Tappable when [onTap] is given
/// (with a matching ink ripple), otherwise a static container. Use for list
/// rows and grouped content.
class BrandCard extends StatelessWidget {
  const BrandCard({
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(BrandDimens.padCard),
    this.radius = BrandDimens.borderCard,
    this.semanticLabel,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final BorderRadius radius;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: brand.cardColor,
        borderRadius: radius,
        border: Border.all(color: brand.cardBorder),
      ),
      child: onTap == null
          ? Padding(padding: padding, child: child)
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: radius,
                onTap: onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: kMinTapTarget),
                  child: Padding(padding: padding, child: child),
                ),
              ),
            ),
    );
    if (semanticLabel == null) return decorated;
    return Semantics(
      button: onTap != null,
      label: semanticLabel,
      child: decorated,
    );
  }
}

/// A standard tappable list row: leading tile · title + subtitle · optional
/// trailing widget, then a disclosure chevron. Mirrors the prototype's apiary
/// / activity / menu rows.
class BrandRowCard extends StatelessWidget {
  const BrandRowCard({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.showChevron = true,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brand = context.brand;
    return BrandCard(
      onTap: onTap,
      semanticLabel: subtitle == null ? title : '$title. $subtitle',
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 14)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                    color: scheme.onSurface,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppTheme.bodyFontFamily,
                      fontSize: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          if (showChevron && onTap != null)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(Icons.chevron_right, color: brand.trailingIcon),
            ),
        ],
      ),
    );
  }
}

/// The sand "sticky note" callout used for apiary/org notes and offline
/// hints.
class NotesCard extends StatelessWidget {
  const NotesCard({
    required this.text,
    this.icon = Icons.sticky_note_2_outlined,
    super.key,
  });

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: brand.notesBg,
        border: Border.all(color: brand.notesBorder),
        borderRadius: BrandDimens.borderCard,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: brand.notesIcon),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontFamily: AppTheme.bodyFontFamily,
                fontSize: 14,
                height: 1.5,
                color: brand.notesText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A centered empty-state message (optionally with an icon above it).
class EmptyState extends StatelessWidget {
  const EmptyState({required this.message, this.icon, super.key});

  final String message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AppTheme.bodyFontFamily,
                fontSize: 15,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A selectable pill chip (type/period/sort filters). Selected fills with
/// [accent]; unselected is an outlined pill. [accent] defaults to the plum
/// secondary so plain filters read as brand-selected.
class BrandChip extends StatelessWidget {
  const BrandChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.accent,
    this.height = BrandDimens.heightChip,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? accent;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accentColor = accent ?? scheme.secondary;
    // On light grounds the selected accent needs a legible on-colour; plum and
    // the type accents are dark enough to carry white.
    final onAccent =
        ThemeData.estimateBrightnessForColor(accentColor) == Brightness.dark
        ? Colors.white
        : scheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected ? accentColor : context.brand.cardColor,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? accentColor : scheme.outline,
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: height, minWidth: height),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: selected ? onAccent : scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A grouped settings/menu card: a rounded card wrapping [rows] separated by
/// hairline dividers (the prototype's Account / Settings lists).
class MenuListCard extends StatelessWidget {
  const MenuListCard({required this.rows, super.key});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i != rows.length - 1) {
        children.add(Divider(height: 1, thickness: 1, color: brand.cardBorder));
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: brand.cardColor,
        border: Border.all(color: brand.cardBorder),
        borderRadius: BrandDimens.borderCardLarge,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

/// A single row inside a [MenuListCard]: leading icon · label · optional
/// trailing (defaults to a disclosure chevron when [onTap] is set).
class MenuRow extends StatelessWidget {
  const MenuRow({
    required this.label,
    this.icon,
    this.trailing,
    this.onTap,
    this.showChevron = true,
    super.key,
  });

  final String label;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brand = context.brand;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMinTapTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, color: scheme.secondary),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: AppTheme.bodyFontFamily,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (trailing != null) trailing!,
                if (trailing == null && showChevron && onTap != null)
                  Icon(Icons.chevron_right, color: brand.trailingIcon),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
