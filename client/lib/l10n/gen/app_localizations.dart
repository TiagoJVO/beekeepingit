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
