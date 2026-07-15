import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('pt'),
  ];

  /// App title, shown in the browser tab and app switcher
  ///
  /// In en, this message translates to:
  /// **'BeekeepingIT'**
  String get appTitle;

  /// Text above the login button
  ///
  /// In en, this message translates to:
  /// **'Sign in to manage your apiaries.'**
  String get loginPrompt;

  /// Primary login action — starts the OIDC redirect to the identity provider
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get loginButton;

  /// Sign-out action in the app bar
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get logout;

  /// Apiaries list screen app bar title
  ///
  /// In en, this message translates to:
  /// **'Apiaries'**
  String get apiariesTitle;

  /// Empty state on the apiaries list
  ///
  /// In en, this message translates to:
  /// **'No apiaries yet. Tap “Add apiary” to create one.'**
  String get apiariesEmpty;

  /// Error state on the apiaries list
  ///
  /// In en, this message translates to:
  /// **'Could not load apiaries: {error}'**
  String apiariesError(String error);

  /// Floating action button to create an apiary
  ///
  /// In en, this message translates to:
  /// **'Add apiary'**
  String get addApiary;

  /// Hive count subtitle on a list row
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No hives} =1{1 hive} other{{count} hives}}'**
  String hiveCountValue(int count);

  /// Create form app bar title
  ///
  /// In en, this message translates to:
  /// **'New apiary'**
  String get newApiaryTitle;

  /// Edit form app bar title
  ///
  /// In en, this message translates to:
  /// **'Edit apiary'**
  String get editApiaryTitle;

  /// Apiary name field label
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get apiaryNameLabel;

  /// Validation message for an empty apiary name
  ///
  /// In en, this message translates to:
  /// **'Enter a name.'**
  String get apiaryNameRequired;

  /// Hive count field label
  ///
  /// In en, this message translates to:
  /// **'Number of hives'**
  String get hiveCountLabel;

  /// Validation message for an invalid hive count
  ///
  /// In en, this message translates to:
  /// **'Enter a number of 0 or more.'**
  String get hiveCountInvalid;

  /// Save the apiary form
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get saveButton;

  /// Delete an apiary from the edit form
  ///
  /// In en, this message translates to:
  /// **'Delete apiary'**
  String get deleteApiary;

  /// Profile screen app bar title
  ///
  /// In en, this message translates to:
  /// **'Your profile'**
  String get profileTitle;

  /// Intro text shown when the profile is not yet complete
  ///
  /// In en, this message translates to:
  /// **'Tell us a bit about yourself to get started.'**
  String get profileOnboardingIntro;

  /// Profile name field label
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get profileNameLabel;

  /// Validation message for an empty profile name
  ///
  /// In en, this message translates to:
  /// **'Enter your name.'**
  String get profileNameRequired;

  /// Profile email field label
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get profileEmailLabel;

  /// Validation message for an empty profile email
  ///
  /// In en, this message translates to:
  /// **'Enter your email.'**
  String get profileEmailRequired;

  /// Validation message for a malformed profile email
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email address.'**
  String get profileEmailInvalid;

  /// Profile locale picker label
  ///
  /// In en, this message translates to:
  /// **'Preferred language'**
  String get profileLocaleLabel;

  /// Submit button on the profile form
  ///
  /// In en, this message translates to:
  /// **'Save profile'**
  String get profileSaveButton;

  /// Snackbar shown after a successful profile save
  ///
  /// In en, this message translates to:
  /// **'Profile saved.'**
  String get profileSaveSuccess;

  /// Error shown after a failed profile save that isn't a field-level validation error
  ///
  /// In en, this message translates to:
  /// **'Could not save your profile: {error}'**
  String profileSaveError(String error);

  /// Organization creation screen app bar title
  ///
  /// In en, this message translates to:
  /// **'Your organization'**
  String get organizationTitle;

  /// Intro text shown when the user has no organization yet
  ///
  /// In en, this message translates to:
  /// **'Create your organization to start managing apiaries.'**
  String get organizationOnboardingIntro;

  /// Organization name field label
  ///
  /// In en, this message translates to:
  /// **'Organization name'**
  String get organizationNameLabel;

  /// Validation message for an empty organization name
  ///
  /// In en, this message translates to:
  /// **'Enter an organization name.'**
  String get organizationNameRequired;

  /// Organization address field label
  ///
  /// In en, this message translates to:
  /// **'Address (optional)'**
  String get organizationAddressLabel;

  /// Submit button on the organization creation form
  ///
  /// In en, this message translates to:
  /// **'Create organization'**
  String get organizationSaveButton;

  /// Snackbar shown after successfully creating an organization
  ///
  /// In en, this message translates to:
  /// **'Organization created.'**
  String get organizationSaveSuccess;

  /// Error shown after a failed organization save that isn't a field-level validation error
  ///
  /// In en, this message translates to:
  /// **'Could not create your organization: {error}'**
  String organizationSaveError(String error);

  /// Members/invitations management screen app bar title
  ///
  /// In en, this message translates to:
  /// **'Members & invitations'**
  String get membersTitle;

  /// Error state on the members screen
  ///
  /// In en, this message translates to:
  /// **'Could not load members: {error}'**
  String membersLoadError(String error);

  /// Invite-by-email field label
  ///
  /// In en, this message translates to:
  /// **'Email to invite'**
  String get membersInviteEmailLabel;

  /// Validation message for an empty invite email
  ///
  /// In en, this message translates to:
  /// **'Enter an email address.'**
  String get membersInviteEmailRequired;

  /// Submit button to send an invitation
  ///
  /// In en, this message translates to:
  /// **'Invite'**
  String get membersInviteButton;

  /// Snackbar shown after successfully sending an invitation
  ///
  /// In en, this message translates to:
  /// **'Invitation sent.'**
  String get membersInviteSuccess;

  /// Error shown after a failed invite/revoke action that isn't a field-level validation error
  ///
  /// In en, this message translates to:
  /// **'Could not complete the request: {error}'**
  String membersInviteError(String error);

  /// Heading above the members list
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get membersSectionTitle;

  /// Empty state for the members list
  ///
  /// In en, this message translates to:
  /// **'No members yet.'**
  String get membersEmpty;

  /// Heading above the invitations list
  ///
  /// In en, this message translates to:
  /// **'Invitations'**
  String get invitationsSectionTitle;

  /// Empty state for the invitations list
  ///
  /// In en, this message translates to:
  /// **'No invitations yet.'**
  String get invitationsEmpty;

  /// Tooltip/action to revoke a pending invitation
  ///
  /// In en, this message translates to:
  /// **'Revoke invitation'**
  String get membersRevokeButton;

  /// Snackbar shown after successfully revoking an invitation
  ///
  /// In en, this message translates to:
  /// **'Invitation revoked.'**
  String get membersRevokeSuccess;

  /// Admin-only action on the account screen, linking to the members/invitations screen (#172, relocated from the apiaries app bar by #197)
  ///
  /// In en, this message translates to:
  /// **'Manage members'**
  String get manageMembers;

  /// Account settings screen app bar title
  ///
  /// In en, this message translates to:
  /// **'Account settings'**
  String get accountTitle;

  /// Heading above the profile fields on the account settings screen
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get accountProfileSectionTitle;

  /// Heading above the change-password action on the account settings screen
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get accountSecuritySectionTitle;

  /// Explanatory text above the change-password button
  ///
  /// In en, this message translates to:
  /// **'Password changes are handled by our sign-in provider, in a new tab.'**
  String get accountChangePasswordHint;

  /// Button that opens the identity provider's account page to change password
  ///
  /// In en, this message translates to:
  /// **'Change password'**
  String get accountChangePasswordButton;

  /// Heading above the admin-only organization actions (manage members) on the account settings screen
  ///
  /// In en, this message translates to:
  /// **'Organization'**
  String get accountOrganizationSectionTitle;

  /// Activities tab label and screen title (bottom nav, #197)
  ///
  /// In en, this message translates to:
  /// **'Activities'**
  String get activitiesTitle;

  /// Journeys tab label and screen title (bottom nav, #197)
  ///
  /// In en, this message translates to:
  /// **'Journeys'**
  String get journeysTitle;

  /// Todos tab label and screen title (bottom nav, #197)
  ///
  /// In en, this message translates to:
  /// **'Todos'**
  String get todosTitle;

  /// Assistant tab label and screen title (bottom nav, #197)
  ///
  /// In en, this message translates to:
  /// **'Assistant'**
  String get assistantTitle;

  /// Placeholder shown on the Activities tab until its real screens land (M3, #197)
  ///
  /// In en, this message translates to:
  /// **'Activities — coming soon'**
  String get activitiesComingSoon;

  /// Placeholder shown on the Journeys tab until its real screens land (M4, #197)
  ///
  /// In en, this message translates to:
  /// **'Journeys — coming soon'**
  String get journeysComingSoon;

  /// Placeholder shown on the Todos tab until its real screens land (M5, #197)
  ///
  /// In en, this message translates to:
  /// **'Todos — coming soon'**
  String get todosComingSoon;

  /// Placeholder shown on the Assistant tab until its real screens land (M8, #197)
  ///
  /// In en, this message translates to:
  /// **'Assistant — coming soon'**
  String get assistantComingSoon;

  /// App-shell header sync-status pill label when connected (#197; real connectivity wiring is #58 — currently a fixed stub)
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get syncStatusOnline;

  /// App-shell header sync-status pill label when disconnected with nothing pending (#197)
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get syncStatusOffline;

  /// App-shell header sync-status pill label when disconnected with pending local changes (#197)
  ///
  /// In en, this message translates to:
  /// **'Offline · {count}'**
  String syncStatusOfflinePending(int count);

  /// Screen-reader label for the header sync-status pill (#197)
  ///
  /// In en, this message translates to:
  /// **'Sync status: {label}. Opens sync settings.'**
  String syncStatusSemanticLabel(String label);

  /// Offline banner shown below the app-shell header with the pending-change count (#197; real pending-count wiring is #58)
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No connection — changes are saved locally} =1{No connection — changes are saved locally (1 to sync)} other{No connection — changes are saved locally ({count} to sync)}}'**
  String offlineBannerMessage(int count);

  /// Toast shown after successfully creating or updating an apiary (#197)
  ///
  /// In en, this message translates to:
  /// **'Apiary saved.'**
  String get apiarySaveSuccess;

  /// Toast shown after successfully deleting an apiary (#197)
  ///
  /// In en, this message translates to:
  /// **'Apiary deleted.'**
  String get apiaryDeleteSuccess;

  /// Toast shown after a failed apiary create/update — resets the form's busy state rather than leaving an indefinite spinner
  ///
  /// In en, this message translates to:
  /// **'Could not save the apiary: {error}'**
  String apiarySaveError(String error);

  /// Toast shown after a failed apiary delete — resets the form's busy state rather than leaving an indefinite spinner
  ///
  /// In en, this message translates to:
  /// **'Could not delete the apiary: {error}'**
  String apiaryDeleteError(String error);

  /// Toast shown when the edit form's initial load of the existing apiary fails — resets the form's busy state rather than leaving an indefinite spinner
  ///
  /// In en, this message translates to:
  /// **'Could not load the apiary: {error}'**
  String apiaryLoadError(String error);

  /// Placeholder text in the apiaries list search field (FR-AP-6, #36)
  ///
  /// In en, this message translates to:
  /// **'Search apiaries by name'**
  String get apiariesSearchHint;

  /// Empty state shown when a search query matches no apiaries (FR-AP-6, #36)
  ///
  /// In en, this message translates to:
  /// **'No apiaries match your search.'**
  String get apiariesSearchNoResults;

  /// Fallback-order banner when device location services are disabled (FR-AP-2, #33)
  ///
  /// In en, this message translates to:
  /// **'Location services are off — showing apiaries by name.'**
  String get apiariesLocationServicesDisabled;

  /// Fallback-order banner when location permission was denied (FR-AP-2, #33)
  ///
  /// In en, this message translates to:
  /// **'Location access denied — showing apiaries by name.'**
  String get apiariesLocationPermissionDenied;

  /// Fallback-order banner when the device location couldn't be determined for another reason (FR-AP-2, #33)
  ///
  /// In en, this message translates to:
  /// **'Location unavailable — showing apiaries by name.'**
  String get apiariesLocationUnavailable;

  /// Retry action on the location-fallback banner (FR-AP-2, #33)
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get apiariesLocationRetry;

  /// Semantic label for the list/map segmented toggle as a group (FR-AP-4, #35)
  ///
  /// In en, this message translates to:
  /// **'Apiaries view'**
  String get apiariesViewToggleLabel;

  /// Tooltip/semantic label for the list segment of the list/map toggle (FR-AP-4, #35)
  ///
  /// In en, this message translates to:
  /// **'List view'**
  String get apiariesViewListAction;

  /// Tooltip/semantic label for the map segment of the list/map toggle (FR-AP-4, #35)
  ///
  /// In en, this message translates to:
  /// **'Map view'**
  String get apiariesViewMapAction;

  /// App-shell header sync-status pill label while an upload/download is in flight (#58)
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get syncStatusSyncing;

  /// App-shell header sync-status pill / account screen status label while the connection-quality gate is backing off after a failed probe (FR-OF-3, sync.md §7.1, #55)
  ///
  /// In en, this message translates to:
  /// **'Waiting for better signal'**
  String get syncStatusWaitingForSignal;

  /// Non-blocking toast shown when an offline edit lost a last-write-wins conflict (sync.md §4.2/§8, D-12 notify-and-fix, #58)
  ///
  /// In en, this message translates to:
  /// **'One of your offline changes was overwritten by a newer edit.'**
  String get syncSupersededNotice;

  /// Non-blocking toast (with a Fix action) shown when an offline write was permanently rejected on upload (sync.md §8 notify-and-fix, D-12, #256/#260)
  ///
  /// In en, this message translates to:
  /// **'One of your changes was rejected and needs fixing.'**
  String get syncRejectedNotice;

  /// App bar title of the needs-fix list — offline writes the server rejected that the user must correct and re-save
  ///
  /// In en, this message translates to:
  /// **'Changes to fix'**
  String get syncNeedsFixTitle;

  /// Empty state of the needs-fix list when there are no rejected offline writes
  ///
  /// In en, this message translates to:
  /// **'No changes need fixing.'**
  String get syncNeedsFixEmpty;

  /// Error state of the needs-fix list when the local read fails
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load the changes to fix: {error}'**
  String syncNeedsFixLoadError(String error);

  /// Count of offline writes awaiting a fix — the account-screen entry, header account-badge tooltip, and needs-fix link label (D-12 notify-and-fix)
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 change needs fixing} other{{count} changes need fixing}}'**
  String syncNeedsFixCount(int count);

  /// Needs-fix list row title for a rejected apiary write
  ///
  /// In en, this message translates to:
  /// **'Apiary change'**
  String get syncNeedsFixApiaryLabel;

  /// Needs-fix list row title for a rejected apiary hive-counter write (#256)
  ///
  /// In en, this message translates to:
  /// **'Hive count change'**
  String get syncNeedsFixCounterLabel;

  /// Needs-fix list row fallback message when the server returned no field-level detail
  ///
  /// In en, this message translates to:
  /// **'This change was rejected and needs your attention.'**
  String get syncNeedsFixGenericProblem;

  /// Needs-fix action (and rejection toast action) that opens the offending record's edit screen to correct and re-save it
  ///
  /// In en, this message translates to:
  /// **'Fix'**
  String get syncNeedsFixFixAction;

  /// Needs-fix action that discards a rejected offline write the user chooses not to fix
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get syncNeedsFixDismissAction;

  /// Section heading on the account screen for sync status + manual sync (#58)
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get accountSyncSectionTitle;

  /// Current sync status line on the account screen (#58)
  ///
  /// In en, this message translates to:
  /// **'Status: {status}'**
  String accountSyncStatusLabel(String status);

  /// Pending-change count line on the account screen (#58)
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Everything is synced.} =1{1 change waiting to sync.} other{{count} changes waiting to sync.}}'**
  String accountSyncPendingCount(int count);

  /// Manual sync trigger button on the account screen — the prototype's “Sincronizar agora” (#58, sync.md §7.1 manual override)
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get accountSyncNowButton;

  /// Toast shown after tapping “Sync now” (#58)
  ///
  /// In en, this message translates to:
  /// **'Sync requested.'**
  String get accountSyncNowTriggered;

  /// Toast shown when a manual sync attempt fails immediately (#58)
  ///
  /// In en, this message translates to:
  /// **'Could not sync right now: {error}'**
  String accountSyncNowError(String error);

  /// Apiary detail screen app bar title (#32)
  ///
  /// In en, this message translates to:
  /// **'Apiary'**
  String get apiaryDetailTitle;

  /// Formatted lat/lon shown on the apiary detail screen when a location is set (#32)
  ///
  /// In en, this message translates to:
  /// **'{lat}, {lon}'**
  String apiaryLocationValue(String lat, String lon);

  /// Apiary detail screen placeholder when no location is set (#32)
  ///
  /// In en, this message translates to:
  /// **'No location set'**
  String get apiaryLocationNotSet;

  /// Label above the notes block on the apiary detail screen, and the notes field label on the form (FR-AP-8, #196)
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get apiaryNotesLabel;

  /// Placeholder hint text in the apiary form's notes field (FR-AP-8, #196)
  ///
  /// In en, this message translates to:
  /// **'Flora, access, observations…'**
  String get apiaryNotesHint;

  /// Action on the apiary detail screen that navigates to the edit form (#32)
  ///
  /// In en, this message translates to:
  /// **'Edit apiary'**
  String get editApiaryAction;

  /// Empty state on the map when no apiary has a stored location (#34 AC)
  ///
  /// In en, this message translates to:
  /// **'No apiaries with a location yet.'**
  String get apiaryMapEmpty;

  /// Label/tooltip for the distinct user-location marker on the map (#34 AC, matches the Melargil prototype's "Você" marker)
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get apiaryMapUserLocationLabel;

  /// Shown when the user-location marker can't be placed because permission was denied or location is unavailable (#34 AC: graceful permission-denied handling)
  ///
  /// In en, this message translates to:
  /// **'Location unavailable — enable location access to see your position on the map.'**
  String get apiaryMapLocationPermissionDenied;

  /// Hint shown on the map before any apiary is selected for the tap-to-measure flow (#37/D-15, matches the Melargil prototype's "Toque em dois apiários para medir a distância entre eles.")
  ///
  /// In en, this message translates to:
  /// **'Tap two apiaries to measure the distance between them.'**
  String get apiaryMapMeasureHintSelectFirst;

  /// Hint shown after the first apiary is selected for the tap-to-measure flow (#37/D-15)
  ///
  /// In en, this message translates to:
  /// **'Selected {name}. Tap another apiary to measure.'**
  String apiaryMapMeasureHintSelectSecond(String name);

  /// Distance result shown after two apiaries are selected (#37/D-15, straight-line/haversine, km)
  ///
  /// In en, this message translates to:
  /// **'{from} to {to}: {distanceKm} km'**
  String apiaryMapMeasureResult(String from, String to, String distanceKm);

  /// Action to clear the current two-apiary measurement selection (#37 AC: selection must be clear and usable)
  ///
  /// In en, this message translates to:
  /// **'Clear selection'**
  String get apiaryMapMeasureClear;

  /// Semantics container label for the satellite/streets layer toggle on the map (#257 AC: gloves-friendly toggle with semantics labels)
  ///
  /// In en, this message translates to:
  /// **'Map layer'**
  String get apiaryMapLayerToggleLabel;

  /// Tooltip/label for the satellite segment of the map layer toggle (#257)
  ///
  /// In en, this message translates to:
  /// **'Satellite'**
  String get apiaryMapLayerSatelliteAction;

  /// Tooltip/label for the streets (OSM) segment of the map layer toggle (#257)
  ///
  /// In en, this message translates to:
  /// **'Streets'**
  String get apiaryMapLayerStreetsAction;

  /// Attribution overlay text shown when the satellite (Esri World Imagery) layer is active (#257 AC: proper attribution overlay for the active tile source; text required by Esri's World Imagery terms of use)
  ///
  /// In en, this message translates to:
  /// **'Powered by Esri — Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community'**
  String get apiaryMapAttributionEsri;

  /// Attribution overlay text shown when the streets (OSM) layer is active (#257 AC: proper attribution overlay for the active tile source; text required by the OSM tile usage policy)
  ///
  /// In en, this message translates to:
  /// **'© OpenStreetMap contributors'**
  String get apiaryMapAttributionOsm;

  /// Optional free-text place name field label on the apiary form, and its label on the detail screen (#252, e.g. "Montargil")
  ///
  /// In en, this message translates to:
  /// **'Place label'**
  String get apiaryPlaceLabelLabel;

  /// Placeholder hint text in the apiary form's place label field (#252)
  ///
  /// In en, this message translates to:
  /// **'e.g. Montargil'**
  String get apiaryPlaceLabelHint;

  /// Section label above the map-pin picker on the apiary form (#252)
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get apiaryLocationSectionLabel;

  /// Button on the apiary form that sets the location to the device's current position (#252)
  ///
  /// In en, this message translates to:
  /// **'Use current location'**
  String get apiaryUseCurrentLocationAction;

  /// Button on the apiary form that expands the embedded map-pin picker (collapsed by default so the Save action stays reachable) (#252)
  ///
  /// In en, this message translates to:
  /// **'Set on map'**
  String get apiarySetOnMapAction;

  /// Button on the apiary form that collapses the expanded map-pin picker (#252)
  ///
  /// In en, this message translates to:
  /// **'Hide map'**
  String get apiaryHideMapAction;

  /// Button on the apiary form that clears the currently-set location (#252 AC: the location is editable and clearable)
  ///
  /// In en, this message translates to:
  /// **'Clear location'**
  String get apiaryLocationClearAction;

  /// Shown on the apiary form when "use current location" fails because location permission was denied or is unavailable — the map-pin picker is offered as the fallback (#252 AC: graceful permission handling)
  ///
  /// In en, this message translates to:
  /// **'Location access denied — you can still place a pin on the map.'**
  String get apiaryFormLocationPermissionDenied;

  /// Status text on the apiary form's map-pin picker when a location is currently set (#252)
  ///
  /// In en, this message translates to:
  /// **'Location set: {lat}, {lon}'**
  String apiaryFormLocationSet(String lat, String lon);

  /// Status text on the apiary form's map-pin picker when no location is set yet (#252)
  ///
  /// In en, this message translates to:
  /// **'No location set — tap the map to place a pin'**
  String get apiaryFormLocationNotSet;

  /// Semantics label for the embedded map-pin picker on the apiary form (#252)
  ///
  /// In en, this message translates to:
  /// **'Map: tap to place the apiary\'s pin'**
  String get apiaryMapPickerLabel;

  /// Distance from the device's current location shown on an apiaries list row, locale-formatted (FR-AP-2, #253)
  ///
  /// In en, this message translates to:
  /// **'{distanceKm} km away'**
  String apiaryDistanceValue(String distanceKm);

  /// Title of the confirmation dialog shown before deleting an apiary (#255)
  ///
  /// In en, this message translates to:
  /// **'Delete apiary?'**
  String get deleteApiaryConfirmTitle;

  /// Body of the confirmation dialog shown before deleting an apiary, naming it (#255 AC)
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes “{name}”. This cannot be undone.'**
  String deleteApiaryConfirmMessage(String name);

  /// Confirm action in the delete-apiary confirmation dialog (#255)
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteApiaryConfirmAction;

  /// Cancel action in the delete-apiary confirmation dialog (#255 AC: cancel is a no-op)
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get deleteApiaryCancelAction;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'pt':
      return AppLocalizationsPt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
