// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'BeekeepingIT';

  @override
  String get loginPrompt => 'Sign in to manage your apiaries.';

  @override
  String get loginButton => 'Sign in';

  @override
  String get loginError =>
      'Couldn\'t sign in — check your connection and try again.';

  @override
  String get logout => 'Sign out';

  @override
  String get apiariesTitle => 'Apiaries';

  @override
  String get apiariesEmpty =>
      'No apiaries yet. Tap “Add apiary” to create one.';

  @override
  String apiariesError(String error) {
    return 'Could not load apiaries: $error';
  }

  @override
  String get addApiary => 'Add apiary';

  @override
  String hiveCountValue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hives',
      one: '1 hive',
      zero: 'No hives',
    );
    return '$_temp0';
  }

  @override
  String get newApiaryTitle => 'New apiary';

  @override
  String get editApiaryTitle => 'Edit apiary';

  @override
  String get apiaryNameLabel => 'Name';

  @override
  String get apiaryNameRequired => 'Enter a name.';

  @override
  String get hiveCountLabel => 'Number of hives';

  @override
  String get hiveCountInvalid => 'Enter a number of 0 or more.';

  @override
  String get saveButton => 'Save';

  @override
  String get deleteApiary => 'Delete apiary';

  @override
  String get profileTitle => 'Your profile';

  @override
  String get profileOnboardingIntro =>
      'Tell us a bit about yourself to get started.';

  @override
  String get profileNameLabel => 'Name';

  @override
  String get profileNameRequired => 'Enter your name.';

  @override
  String get profileEmailLabel => 'Email';

  @override
  String get profileEmailRequired => 'Enter your email.';

  @override
  String get profileEmailInvalid => 'Enter a valid email address.';

  @override
  String get profileLocaleLabel => 'Preferred language';

  @override
  String get profileSaveButton => 'Save profile';

  @override
  String get profileSaveSuccess => 'Profile saved.';

  @override
  String profileSaveError(String error) {
    return 'Could not save your profile: $error';
  }

  @override
  String get organizationTitle => 'Your organization';

  @override
  String get organizationOnboardingIntro =>
      'Create your organization to start managing apiaries.';

  @override
  String get organizationNameLabel => 'Organization name';

  @override
  String get organizationNameRequired => 'Enter an organization name.';

  @override
  String get organizationAddressLabel => 'Address (optional)';

  @override
  String get organizationSaveButton => 'Create organization';

  @override
  String get organizationSaveSuccess => 'Organization created.';

  @override
  String organizationSaveError(String error) {
    return 'Could not create your organization: $error';
  }

  @override
  String get membersTitle => 'Members & invitations';

  @override
  String membersLoadError(String error) {
    return 'Could not load members: $error';
  }

  @override
  String get membersInviteEmailLabel => 'Email to invite';

  @override
  String get membersInviteEmailRequired => 'Enter an email address.';

  @override
  String get membersInviteButton => 'Invite';

  @override
  String get membersInviteSuccess => 'Invitation sent.';

  @override
  String membersInviteError(String error) {
    return 'Could not complete the request: $error';
  }

  @override
  String get membersSectionTitle => 'Members';

  @override
  String get membersEmpty => 'No members yet.';

  @override
  String get invitationsSectionTitle => 'Invitations';

  @override
  String get invitationsEmpty => 'No invitations yet.';

  @override
  String get membersRevokeButton => 'Revoke invitation';

  @override
  String get membersRevokeSuccess => 'Invitation revoked.';

  @override
  String get manageMembers => 'Manage members';

  @override
  String get accountTitle => 'Account settings';

  @override
  String get accountProfileSectionTitle => 'Profile';

  @override
  String get accountSecuritySectionTitle => 'Security';

  @override
  String get accountChangePasswordHint =>
      'Password changes are handled by our sign-in provider, in a new tab.';

  @override
  String get accountChangePasswordButton => 'Change password';

  @override
  String get accountOrganizationSectionTitle => 'Organization';

  @override
  String get activitiesTitle => 'Activities';

  @override
  String get journeysTitle => 'Journeys';

  @override
  String get todosTitle => 'Todos';

  @override
  String get assistantTitle => 'Assistant';

  @override
  String get activitiesComingSoon => 'Activities — coming soon';

  @override
  String get journeysComingSoon => 'Journeys — coming soon';

  @override
  String get todosComingSoon => 'Todos — coming soon';

  @override
  String get assistantComingSoon => 'Assistant — coming soon';

  @override
  String get syncStatusOnline => 'Online';

  @override
  String get syncStatusOffline => 'Offline';

  @override
  String syncStatusOfflinePending(int count) {
    return 'Offline · $count';
  }

  @override
  String syncStatusSemanticLabel(String label) {
    return 'Sync status: $label. Opens sync settings.';
  }

  @override
  String offlineBannerMessage(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'No connection — changes are saved locally ($count to sync)',
      one: 'No connection — changes are saved locally (1 to sync)',
      zero: 'No connection — changes are saved locally',
    );
    return '$_temp0';
  }

  @override
  String get apiarySaveSuccess => 'Apiary saved.';

  @override
  String get apiaryDeleteSuccess => 'Apiary deleted.';

  @override
  String get apiariesSearchHint => 'Search apiaries by name';

  @override
  String get apiariesSearchNoResults => 'No apiaries match your search.';

  @override
  String get apiariesLocationServicesDisabled =>
      'Location services are off — showing apiaries by name.';

  @override
  String get apiariesLocationPermissionDenied =>
      'Location access denied — showing apiaries by name.';

  @override
  String get apiariesLocationUnavailable =>
      'Location unavailable — showing apiaries by name.';

  @override
  String get apiariesLocationRetry => 'Retry';

  @override
  String get apiariesViewToggleLabel => 'Apiaries view';

  @override
  String get apiariesViewListAction => 'List view';

  @override
  String get apiariesViewMapAction => 'Map view';

  @override
  String get syncStatusSyncing => 'Syncing…';

  @override
  String get syncStatusWaitingForSignal => 'Waiting for better signal';

  @override
  String get syncStatusError => 'Sync error';

  @override
  String get offlineBannerErrorMessage =>
      'Some changes failed to sync and PowerSync is retrying.';

  @override
  String get syncSupersededNotice =>
      'One of your offline changes was overwritten by a newer edit.';

  @override
  String get syncRejectedNotice =>
      'One of your changes was rejected and needs fixing.';

  @override
  String get syncNeedsFixTitle => 'Changes to fix';

  @override
  String get syncNeedsFixEmpty => 'No changes need fixing.';

  @override
  String syncNeedsFixLoadError(String error) {
    return 'Couldn\'t load the changes to fix: $error';
  }

  @override
  String syncNeedsFixCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes need fixing',
      one: '1 change needs fixing',
    );
    return '$_temp0';
  }

  @override
  String get syncNeedsFixApiaryLabel => 'Apiary change';

  @override
  String get syncNeedsFixCounterLabel => 'Hive count change';

  @override
  String get syncNeedsFixGenericProblem =>
      'This change was rejected and needs your attention.';

  @override
  String get syncNeedsFixFixAction => 'Fix';

  @override
  String get syncNeedsFixDismissAction => 'Dismiss';

  @override
  String get accountSyncSectionTitle => 'Sync';

  @override
  String accountSyncStatusLabel(String status) {
    return 'Status: $status';
  }

  @override
  String accountSyncPendingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes waiting to sync.',
      one: '1 change waiting to sync.',
      zero: 'Everything is synced.',
    );
    return '$_temp0';
  }

  @override
  String get accountSyncNowButton => 'Sync now';

  @override
  String get accountSyncNowTriggered => 'Sync requested.';

  @override
  String accountSyncNowError(String error) {
    return 'Could not sync right now: $error';
  }

  @override
  String get apiaryDetailTitle => 'Apiary';

  @override
  String apiaryLocationValue(String lat, String lon) {
    return '$lat, $lon';
  }

  @override
  String get apiaryLocationNotSet => 'No location set';

  @override
  String get apiaryNotesLabel => 'Notes';

  @override
  String get apiaryNotesHint => 'Flora, access, observations…';

  @override
  String get editApiaryAction => 'Edit apiary';

  @override
  String get apiaryMapEmpty => 'No apiaries with a location yet.';

  @override
  String get apiaryMapUserLocationLabel => 'You';

  @override
  String get apiaryMapLocationPermissionDenied =>
      'Location unavailable — enable location access to see your position on the map.';

  @override
  String get apiaryMapMeasureHintSelectFirst =>
      'Tap two apiaries to measure the distance between them.';

  @override
  String apiaryMapMeasureHintSelectSecond(String name) {
    return 'Selected $name. Tap another apiary to measure.';
  }

  @override
  String apiaryMapMeasureResult(String from, String to, String distanceKm) {
    return '$from to $to: $distanceKm km';
  }

  @override
  String get apiaryMapMeasureClear => 'Clear selection';

  @override
  String get apiaryMapLayerToggleLabel => 'Map layer';

  @override
  String get apiaryMapLayerSatelliteAction => 'Satellite';

  @override
  String get apiaryMapLayerStreetsAction => 'Streets';

  @override
  String get apiaryMapAttributionEsri =>
      'Powered by Esri — Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community';

  @override
  String get apiaryMapAttributionOsm => '© OpenStreetMap contributors';

  @override
  String get apiaryPlaceLabelLabel => 'Place label';

  @override
  String get apiaryPlaceLabelHint => 'e.g. Montargil';

  @override
  String get apiaryLocationSectionLabel => 'Location';

  @override
  String get apiaryUseCurrentLocationAction => 'Use current location';

  @override
  String get apiarySetOnMapAction => 'Set on map';

  @override
  String get apiaryHideMapAction => 'Hide map';

  @override
  String get apiaryLocationClearAction => 'Clear location';

  @override
  String get apiaryFormLocationPermissionDenied =>
      'Location access denied — you can still place a pin on the map.';

  @override
  String apiaryFormLocationSet(String lat, String lon) {
    return 'Location set: $lat, $lon';
  }

  @override
  String get apiaryFormLocationNotSet =>
      'No location set — tap the map to place a pin';

  @override
  String get apiaryMapPickerLabel => 'Map: tap to place the apiary\'s pin';

  @override
  String apiaryDistanceValue(String distanceKm) {
    return '$distanceKm km away';
  }

  @override
  String get deleteApiaryConfirmTitle => 'Delete apiary?';

  @override
  String deleteApiaryConfirmMessage(String name) {
    return 'This permanently deletes “$name”. This cannot be undone.';
  }

  @override
  String get deleteApiaryConfirmAction => 'Delete';

  @override
  String get deleteApiaryCancelAction => 'Cancel';
}
