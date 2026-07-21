import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../core/geo/device_location.dart';
import '../../core/widgets/field_action_button.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import 'apiaries_repository.dart';

/// Default map-picker center/zoom when no location is set yet — same
/// mainland-Portugal default as apiary_map_screen.dart's `_fallbackCenter`
/// (the Melargil prototype and this project's dev-seed data are
/// Portugal-based).
const _pickerFallbackCenter = ll.LatLng(39.5, -8.0);
const _pickerFallbackZoom = 6.0;
const _pickerFocusedZoom = 13.0;

/// Create (when [apiaryId] is null) or edit an apiary. Writes go local-first
/// through the repository; there is no direct REST write (walking-skeleton.md
/// §4.4).
///
/// Location capture (#252, FR-AP-2/3/5): the map/proximity/measure features
/// already read the apiary's stored PostGIS location, but until this issue
/// the form never SET it, so an in-app-created apiary had no coordinates.
/// Two ways to set it, matching the AC: an embedded [_LocationPicker]
/// (`flutter_map`, tap to place/move the pin — reusing apiary_map_screen.dart's
/// satellite tile layer) and a "use current location" button (`geolocator`,
/// the same graceful-permission-handling pattern the map screen already
/// uses for its own user-location marker). An optional free-text
/// [_placeLabelController] (e.g. "Montargil") is stored independently.
///
/// The map picker is **collapsed by default** ([_mapPickerExpanded]) — it
/// expands inline only when the user taps "Set on map", or automatically
/// when editing an apiary that already has a location. Location is now
/// **mandatory** (FR-AP-7, #341 — the product owner's directed requirement
/// change): the form cannot be saved without one (see [_save]'s
/// [_locationError] check). The picker is still collapsed by default so the
/// primary Save action is never pushed below the fold or obscured by an
/// always-on 220px map in the scrollable form (the map's own gesture region
/// also competes with the form's scroll); a compact summary + on-demand
/// expansion keeps the create form short and Save reachable while still
/// offering the embedded map picker.
class ApiaryFormScreen extends ConsumerStatefulWidget {
  const ApiaryFormScreen({this.apiaryId, super.key});

  final String? apiaryId;
  bool get isEdit => apiaryId != null;

  @override
  ConsumerState<ApiaryFormScreen> createState() => _ApiaryFormScreenState();
}

class _ApiaryFormScreenState extends ConsumerState<ApiaryFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _notesController = TextEditingController();
  final _placeLabelController = TextEditingController();
  bool _busy = false;

  /// The pin's current position, or null when no location is set — mirrors
  /// [Apiary.hasLocation]'s "both or neither" convention. Editable/clearable
  /// per #252's AC via [_LocationPicker]'s tap handler, the "use current
  /// location" action, and the "clear location" action.
  ll.LatLng? _location;
  bool _locationPermissionDenied = false;

  /// Set to the localized "location is required" message when the user tries
  /// to save without a location (FR-AP-7, #341 — location is mandatory).
  /// Cleared as soon as a location is set (map tap / use-current-location) so
  /// the error never lingers past the fix. Manual rather than a
  /// [TextFormField] validator because the location isn't a text field — it's
  /// a map pin held in [_location] outside the [Form]'s field tree.
  String? _locationError;

  /// Whether the inline map picker is expanded. Collapsed by default (keeps
  /// the primary Save action reachable — see the class doc comment); the
  /// user expands it via "Set on map", and it auto-expands when editing an
  /// apiary that already has a location so the existing pin is visible.
  bool _mapPickerExpanded = false;

  @override
  void initState() {
    super.initState();
    if (widget.isEdit) _loadExisting();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    _placeLabelController.dispose();
    super.dispose();
  }

  Future<void> _loadExisting() async {
    setState(() => _busy = true);
    // HIGH finding: this used to have no error handling at all — a thrown
    // repository/lookup failure left `_busy` stuck true forever (an
    // indefinite spinner, no way out) with no message. l10n/messenger are
    // deliberately NOT grabbed here at the top (unlike _save/_delete, which
    // are always button-triggered): _loadExisting runs synchronously from
    // initState() up to its first `await`, and looking up an
    // InheritedWidget (AppLocalizations.of/ScaffoldMessenger.of) during
    // initState throws ("dependOnInheritedWidgetOfExactType() ... called
    // before initState() completed") — so they're only read inside the
    // catch block below, which can only run after the first await has
    // already suspended and resumed.
    try {
      final repo = await ref.read(apiariesRepositoryProvider.future);
      final existing = await repo.getById(widget.apiaryId!);
      if (!mounted) return;
      if (existing != null) {
        _nameController.text = existing.name;
        _notesController.text = existing.notes ?? '';
        _placeLabelController.text = existing.placeLabel ?? '';
        if (existing.hasLocation) {
          _location = ll.LatLng(existing.locationLat!, existing.locationLon!);
          // Show the existing pin without an extra tap when editing a
          // located apiary — the collapse-by-default rule is about keeping
          // a fresh create form short, not hiding a location the apiary
          // already has.
          _mapPickerExpanded = true;
        }
      }
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.apiaryLoadError('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "Use current location" (#252 AC): a fresh, explicit one-shot fetch via
  /// the module's shared [deviceLocationServiceProvider] (CRITICAL fix —
  /// this used to re-implement raw Geolocator.*/permission-handling calls
  /// directly, an independent copy of apiary_map_screen.dart's own
  /// (now-also-fixed) logic). Deliberately reads the *service* directly
  /// rather than the cached `deviceLocationProvider` (core/geo/
  /// device_location.dart): tapping this button means "get where I am
  /// RIGHT NOW", which should always re-request, not silently reuse
  /// whatever the list/map screens' shared cache last resolved to.
  /// [DeviceLocationService.current] never throws (its own doc comment) —
  /// it resolves to one of [DeviceLocation]'s variants — so no try/catch is
  /// needed here; the switch simply collapses every non-available variant
  /// onto the same "denied/unavailable" UI state.
  Future<void> _useCurrentLocation() async {
    final result = await ref.read(deviceLocationServiceProvider).current();
    if (!mounted) return;
    setState(() {
      switch (result) {
        case DeviceLocationAvailable(:final lon, :final lat):
          _location = ll.LatLng(lat, lon);
          _locationPermissionDenied = false;
          _locationError = null;
          // Reveal the pin that was just set so the user can confirm/adjust it.
          _mapPickerExpanded = true;
        default:
          _locationPermissionDenied = true;
      }
    });
  }

  void _onMapTap(ll.LatLng point) {
    setState(() {
      _location = point;
      _locationPermissionDenied = false;
      _locationError = null;
    });
  }

  void _clearLocation() => setState(() => _location = null);

  void _toggleMapPicker() =>
      setState(() => _mapPickerExpanded = !_mapPickerExpanded);

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final formOk = _formKey.currentState!.validate();
    // Location is mandatory (FR-AP-7, #341): an apiary cannot be saved without
    // one. The map pin lives in [_location], outside the Form's field tree, so
    // it's validated here rather than via a TextFormField validator — surfaced
    // as [_locationError] next to the location section.
    final locationOk = _location != null;
    setState(() => _locationError = locationOk ? null : l10n.apiaryLocationRequired);
    if (!formOk || !locationOk) return;
    // The shell's Scaffold (not this screen's, which navigates away right
    // after) owns the messenger the toast should surface on — grabbed via
    // the root navigator's context before the local-first write completes
    // and this screen is popped (walking-skeleton.md §4.4: this confirms
    // the on-device write, not that it has synced — that's #58's job).
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    // HIGH finding: no try/catch previously wrapped repo.update/create — a
    // thrown error left `_busy` stuck true forever (an indefinite spinner)
    // with no error message and no way to retry.
    try {
      final repo = await ref.read(apiariesRepositoryProvider.future);
      final name = _nameController.text.trim();
      final notes = _notesController.text.trim();
      final placeLabel = _placeLabelController.text.trim();
      // The form no longer sets any counter (#346, D-20): hive count and
      // every other counter type are managed on the detail screen, so create
      // omits hiveCount ("no counter set at creation") and edit never touches
      // the counter rows here.
      if (widget.isEdit) {
        await repo.update(
          widget.apiaryId!,
          name: name,
          notes: notes.isEmpty ? null : notes,
          notesProvided: true,
          placeLabel: placeLabel.isEmpty ? null : placeLabel,
          placeLabelProvided: true,
          locationLon: _location?.longitude,
          locationLat: _location?.latitude,
          locationProvided: true,
        );
        if (!mounted) return;
        context.go('/apiaries/${widget.apiaryId}');
      } else {
        await repo.create(
          name: name,
          notes: notes.isEmpty ? null : notes,
          placeLabel: placeLabel.isEmpty ? null : placeLabel,
          locationLon: _location?.longitude,
          locationLat: _location?.latitude,
        );
        if (!mounted) return;
        context.go('/apiaries');
      }
      messenger.showSnackBar(SnackBar(content: Text(l10n.apiarySaveSuccess)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.apiarySaveError('$e'))),
      );
    }
  }

  /// Delete confirmation (#255, FR-UX-1, D-18): the field-first checklist
  /// reserves interruption for destructive/hard-to-undo actions — delete is
  /// exactly that (a gloved mis-tap on the previously-immediate delete
  /// button destroyed the apiary and synced the deletion org-wide). Danger
  /// styling reuses the theme's error color (the same `destructive` tint
  /// `SecondaryActionButton` already applies to this very delete button),
  /// 44px+ targets via [PrimaryActionButton]/`TextButton` sized to
  /// [kMinTapTarget], and a semantics label naming the apiary. Confirm
  /// deletes and toasts as before; cancel is a no-op (dismisses only).
  Future<void> _confirmDelete() async {
    final name = _nameController.text.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => DeleteApiaryConfirmDialog(apiaryName: name),
    );
    // MEDIUM finding: missing mounted check after the await, inconsistent
    // with the rest of the file (e.g. _save/_delete both check it
    // immediately after their own awaits) — without it, a screen disposed
    // while the dialog was open would call _delete(), which touches
    // context-dependent objects (AppLocalizations.of/ScaffoldMessenger.of)
    // on an unmounted State.
    if (!mounted) return;
    if (confirmed != true) return;
    await _delete();
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    // HIGH finding: no try/catch previously wrapped repo.delete — a thrown
    // error left `_busy` stuck true forever with no error message.
    try {
      final repo = await ref.read(apiariesRepositoryProvider.future);
      await repo.delete(widget.apiaryId!);
      if (!mounted) return;
      context.go('/apiaries');
      messenger.showSnackBar(SnackBar(content: Text(l10n.apiaryDeleteSuccess)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.apiaryDeleteError('$e'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // No own AppBar/Scaffold here (unlike a standalone route): this screen is
    // pushed inside the app shell's Apiaries tab (FR-UX-2, #197), which
    // already renders the contextual back button + screen title in its own
    // header — a second AppBar here would double up that chrome.
    return _busy
        ? const Center(child: CircularProgressIndicator())
        : Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        key: const Key('apiary-name-field'),
                        controller: _nameController,
                        autofocus: !widget.isEdit,
                        decoration: InputDecoration(
                          labelText: l10n.apiaryNameLabel,
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? l10n.apiaryNameRequired
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('apiary-place-label-field'),
                        controller: _placeLabelController,
                        textInputAction: TextInputAction.next,
                        maxLength: 200,
                        decoration: InputDecoration(
                          labelText: l10n.apiaryPlaceLabelLabel,
                          hintText: l10n.apiaryPlaceLabelHint,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.apiaryLocationSectionLabel,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 4),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _location == null
                              ? l10n.apiaryFormLocationNotSet
                              : l10n.apiaryFormLocationSet(
                                  _location!.latitude.toStringAsFixed(5),
                                  _location!.longitude.toStringAsFixed(5),
                                ),
                          key: const Key('apiary-location-status'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (_locationPermissionDenied) ...[
                        const SizedBox(height: 4),
                        Text(
                          l10n.apiaryFormLocationPermissionDenied,
                          key: const Key('apiary-location-permission-denied'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                        ),
                      ],
                      // Location-required validation error (FR-AP-7, #341):
                      // shown when the user tries to save without a location.
                      // liveRegion so a screen reader announces it when it
                      // appears (WCAG 2.2 AA).
                      if (_locationError != null) ...[
                        const SizedBox(height: 4),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _locationError!,
                            key: const Key('apiary-location-required-error'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                          ),
                        ),
                      ],
                      // Location capture is COLLAPSED by default: only a single
                      // compact "set on map" toggle shows until the user opts
                      // in. This keeps the primary Save action reachable in a
                      // fresh create form — an always-on 220px map + its
                      // control buttons used to push Save below the fold and
                      // collide with it in a constrained viewport (the
                      // regression the walking-skeleton e2e caught). When
                      // expanded, the full picker + "use current location" +
                      // "clear" appear.
                      const SizedBox(height: 8),
                      SecondaryActionButton(
                        key: const Key('apiary-toggle-map-button'),
                        label: _mapPickerExpanded
                            ? l10n.apiaryHideMapAction
                            : l10n.apiarySetOnMapAction,
                        icon: _mapPickerExpanded
                            ? Icons.expand_less
                            : Icons.map_outlined,
                        onPressed: _toggleMapPicker,
                      ),
                      if (_mapPickerExpanded) ...[
                        const SizedBox(height: 8),
                        _LocationPicker(location: _location, onTap: _onMapTap),
                        const SizedBox(height: 8),
                        SecondaryActionButton(
                          key: const Key('apiary-use-current-location-button'),
                          label: l10n.apiaryUseCurrentLocationAction,
                          icon: Icons.my_location,
                          onPressed: _useCurrentLocation,
                        ),
                        if (_location != null) ...[
                          const SizedBox(height: 8),
                          SecondaryActionButton(
                            key: const Key('apiary-clear-location-button'),
                            label: l10n.apiaryLocationClearAction,
                            icon: Icons.location_off_outlined,
                            onPressed: _clearLocation,
                          ),
                        ],
                      ],
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('apiary-notes-field'),
                        controller: _notesController,
                        minLines: 3,
                        maxLines: 6,
                        maxLength: 10000,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          labelText: l10n.apiaryNotesLabel,
                          hintText: l10n.apiaryNotesHint,
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 24),
                      PrimaryActionButton(
                        key: const Key('apiary-save-button'),
                        label: l10n.saveButton,
                        onPressed: _save,
                      ),
                      if (widget.isEdit) ...[
                        const SizedBox(height: 12),
                        SecondaryActionButton(
                          key: const Key('apiary-delete-button'),
                          label: l10n.deleteApiary,
                          icon: Icons.delete_outline,
                          destructive: true,
                          onPressed: _confirmDelete,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
  }
}

/// The embedded map-pin picker (#252 AC: "placing/dragging a pin on an
/// embedded map picker"). A single tap places/moves the pin — flutter_map
/// has no built-in draggable-marker gesture, and a tap-to-place interaction
/// is both simpler and already the established pattern this app's map
/// screen uses for its own tap-to-measure selection
/// (apiary_map_screen.dart's `_onApiaryTap`), so "drag" here means
/// "tap again elsewhere to move it" rather than a press-and-drag gesture —
/// fully equivalent for placing a pin, and far less finicky on a touchscreen
/// (especially gloved, FR-UX-1) than precision dragging would be. Reuses
/// the satellite tile layer + attribution apiary_map_screen.dart already
/// established (#257) rather than re-deriving a tile source, since a field
/// user recognizes terrain/tree cover for siting an apiary the same way
/// they do when browsing the full map.
class _LocationPicker extends StatelessWidget {
  const _LocationPicker({required this.location, required this.onTap});

  final ll.LatLng? location;
  final void Function(ll.LatLng) onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      label: l10n.apiaryMapPickerLabel,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          key: const Key('apiary-location-picker'),
          height: 220,
          child: Stack(
            children: [
              FlutterMap(
                options: MapOptions(
                  initialCenter: location ?? _pickerFallbackCenter,
                  initialZoom: location != null
                      ? _pickerFocusedZoom
                      : _pickerFallbackZoom,
                  onTap: (tapPosition, point) => onTap(point),
                ),
                children: [
                  TileLayer(
                    key: const Key('apiary-location-picker-tile-layer'),
                    urlTemplate:
                        'https://server.arcgisonline.com/ArcGIS/rest/services/'
                        'World_Imagery/MapServer/tile/{z}/{y}/{x}',
                    userAgentPackageName: 'com.beekeepingit.client',
                  ),
                  if (location != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          key: const Key('apiary-location-picker-pin'),
                          point: location!,
                          width: 44,
                          height: 44,
                          child: Icon(
                            Icons.location_on,
                            color: Theme.of(context).colorScheme.primary,
                            size: 36,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              Positioned(
                right: 6,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    l10n.apiaryMapAttributionEsri,
                    key: const Key('apiary-location-picker-attribution'),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirmation dialog shown before deleting an apiary (#255, FR-UX-1,
/// D-18). Pulled out as its own public widget (rather than an inline
/// `showDialog` builder closure) so it's directly pumpable/testable without
/// needing the full [ApiaryFormScreen] to have finished loading an existing
/// apiary first — that screen's edit-mode data load depends on a real
/// PowerSync-backed repository this test environment can't stand up (see
/// apiary_form_screen_test.dart's doc comments on that existing limit); this
/// dialog has no such dependency, taking only the plain [apiaryName] string
/// to interpolate into its message.
///
/// The field-first checklist (docs/design/accessibility-field-ux-checklist.md)
/// reserves interruption for destructive/hard-to-undo actions — delete is
/// exactly that (a gloved mis-tap on the previously-immediate delete button
/// destroyed the apiary and synced the deletion org-wide). Danger styling
/// reuses the theme's error color (the same `destructive` tint
/// `SecondaryActionButton` already applies to the delete button that opens
/// this), 44px+ tap targets via [kMinTapTarget], and semantics labels naming
/// the apiary (via [AlertDialog]'s own title/content, which
/// `showDialog`/`AlertDialog` already exposes to a screen reader). Pops
/// `true` on confirm, `false` on cancel/dismiss — the caller
/// (`_ApiaryFormScreenState._confirmDelete`) only deletes on an explicit
/// `true`, so a barrier-dismiss or back-button dismissal is treated the same
/// as Cancel (#255 AC: "cancel is a no-op").
class DeleteApiaryConfirmDialog extends StatelessWidget {
  const DeleteApiaryConfirmDialog({required this.apiaryName, super.key});

  final String apiaryName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('apiary-delete-confirm-dialog'),
      icon: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
      title: Text(l10n.deleteApiaryConfirmTitle),
      content: Text(l10n.deleteApiaryConfirmMessage(apiaryName)),
      actions: [
        TextButton(
          key: const Key('apiary-delete-confirm-cancel'),
          style: TextButton.styleFrom(
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.deleteApiaryCancelAction),
        ),
        TextButton(
          key: const Key('apiary-delete-confirm-delete'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.deleteApiaryConfirmAction),
        ),
      ],
    );
  }
}
