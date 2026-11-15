import 'package:flutter/material.dart';
import 'ui_theme.dart';

class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  const AppHeader(
      {super.key,
      this.title,
      this.subtitle,
      this.onBack,
      this.onMenu,
      this.actions = const []});
  final String? title;
  final String? subtitle;
  final VoidCallback? onBack;
  final VoidCallback? onMenu;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(76);

  @override
  Widget build(BuildContext context) => AppBar(
        automaticallyImplyLeading: false,
        leading: onBack != null
            ? CircleIconButton(icon: Icons.arrow_back, onPressed: onBack!)
            : onMenu != null
                ? CircleIconButton(
                    tooltip: 'Open menu', icon: Icons.menu, onPressed: onMenu!)
                : null,
        title: Row(
          children: [
            Image.asset('assets/images/logo.png', width: 34, height: 34),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title ?? 'RideGuard',
                    style: Theme.of(context).textTheme.titleLarge),
                if (subtitle != null)
                  Text(subtitle!,
                      style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ],
        ),
        actions: actions,
      );
}

class CircleIconButton extends StatelessWidget {
  const CircleIconButton(
      {super.key, required this.icon, required this.onPressed, this.tooltip});
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 21),
        style: IconButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          foregroundColor: Theme.of(context).colorScheme.primary,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.all(10),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(RideTheme.radiusSmall)),
        ),
      );
}

class PillButton extends StatelessWidget {
  const PillButton(
      {super.key,
      required this.label,
      required this.onPressed,
      this.icon,
      this.dark = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool dark;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: dark ? RideTheme.dark : RideTheme.primary,
        ),
        icon: icon == null ? const SizedBox.shrink() : Icon(icon),
        label: Text(label),
      );
}

class StatusTag extends StatelessWidget {
  const StatusTag(this.label, {super.key, this.color = RideTheme.primary});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          borderRadius: BorderRadius.circular(RideTheme.radiusPill),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

class StatCard extends StatelessWidget {
  const StatCard(
      {super.key,
      required this.title,
      required this.value,
      required this.caption,
      this.unit,
      this.action});
  final String title;
  final String value;
  final String caption;
  final String? unit;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.bodyMedium)),
              if (action != null)
                TextButton(
                    onPressed: action, child: const Text('View details')),
            ]),
            const SizedBox(height: 12),
            Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(value, style: Theme.of(context).textTheme.displayLarge),
                  if (unit != null) ...[
                    const SizedBox(width: 6),
                    Text(unit!, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ]),
            const SizedBox(height: 4),
            Text(caption, style: Theme.of(context).textTheme.bodyMedium),
          ]),
        ),
      );
}

class ChipRow extends StatelessWidget {
  const ChipRow(
      {super.key, required this.items, this.selected = 0, this.onSelected});
  final List<String> items;
  final int selected;
  final ValueChanged<int>? onSelected;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (var i = 0; i < items.length; i++) ...[
            ChoiceChip(
              label: Text(items[i]),
              selected: i == selected,
              onSelected: (_) => onSelected?.call(i),
              selectedColor: RideTheme.primaryTint,
              labelStyle: TextStyle(
                  color: i == selected
                      ? RideTheme.primary
                      : RideTheme.textSecondary),
              side: const BorderSide(color: RideTheme.border),
            ),
            const SizedBox(width: 8),
          ],
        ]),
      );
}
