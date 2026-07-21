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

  /// Shown on the login screen when starting sign-in fails (e.g. OIDC discovery unreachable while offline); tapping "Sign in" again retries
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t sign in — check your connection and try again.'**
  String get loginError;

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

  /// Label for the single expandable quick-actions button (FR-UX-2) that, when tapped, reveals the contextual actions available on the current screen; also its screen-reader name, whose expanded/collapsed state is announced.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get actionsMenuLabel;

  /// Hive count subtitle on a list row
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No hives} =1{1 hive} other{{count} hives}}'**
  String hiveCountValue(int count);

  /// Supers counter value badge on the apiary detail screen (#346, D-20)
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No supers} =1{1 super} other{{count} supers}}'**
  String superCountValue(int count);

  /// The name of the hive counter type, used by the detail screen's add-counter picker and inline value editor (#346)
  ///
  /// In en, this message translates to:
  /// **'Hives'**
  String get counterTypeHiveLabel;

  /// The name of the supers counter type, used by the detail screen's add-counter picker and inline value editor (#346)
  ///
  /// In en, this message translates to:
  /// **'Supers'**
  String get counterTypeSuperLabel;

  /// Button on the apiary detail screen that opens the add-counter type picker (#346)
  ///
  /// In en, this message translates to:
  /// **'Add counter'**
  String get apiaryAddCounterAction;

  /// Title of the add-counter type picker sheet on the apiary detail screen (#346)
  ///
  /// In en, this message translates to:
  /// **'Add a counter'**
  String get apiaryAddCounterTitle;

  /// Empty state in the add-counter picker when the apiary already has a counter of every known type (#346)
  ///
  /// In en, this message translates to:
  /// **'Every counter type is already here.'**
  String get apiaryNoCountersToAdd;

  /// Accessibility label for the minus button in the inline counter value editor (#346)
  ///
  /// In en, this message translates to:
  /// **'Decrease'**
  String get counterDecrementLabel;

  /// Accessibility label for the plus button in the inline counter value editor (#346)
  ///
  /// In en, this message translates to:
  /// **'Increase'**
  String get counterIncrementLabel;

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

  /// Fixed, non-interpolated message shown when the profile fails to load, or a save fails with something other than a structured ApiException — never the raw exception text (avoids leaking internal error details to the field user)
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get profileGenericError;

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

  /// Validation message for a malformed invite email
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email address.'**
  String get membersInviteEmailInvalid;

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

  /// Localized label for the 'admin' member/invitation role (organizations migration 00001/00002: role IN ('admin', 'user'))
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get memberRoleAdmin;

  /// Localized label for the 'user' member/invitation role
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get memberRoleUser;

  /// Localized label for a membership's 'active' status (organizations migration 00001: status IN ('active', 'invited', 'removed'))
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get memberStatusActive;

  /// Localized label for a membership's 'invited' status
  ///
  /// In en, this message translates to:
  /// **'Invited'**
  String get memberStatusInvited;

  /// Localized label for a membership's 'removed' status
  ///
  /// In en, this message translates to:
  /// **'Removed'**
  String get memberStatusRemoved;

  /// Localized label for an invitation's 'pending' status (organizations migration 00002: status IN ('pending', 'accepted', 'expired', 'revoked'))
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get invitationStatusPending;

  /// Localized label for an invitation's 'accepted' status
  ///
  /// In en, this message translates to:
  /// **'Accepted'**
  String get invitationStatusAccepted;

  /// Localized label for an invitation's 'expired' status
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get invitationStatusExpired;

  /// Localized label for an invitation's 'revoked' status
  ///
  /// In en, this message translates to:
  /// **'Revoked'**
  String get invitationStatusRevoked;

  /// Action to fetch the next cursor-paginated page of members/invitations (server: limit/cursor/page.next_cursor)
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get membersLoadMoreButton;

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

  /// App-shell header sync-status pill label when the last upload/download attempt errored and PowerSync is waiting to retry (SyncStatus.hasError) — distinct from merely offline, so a beekeeper whose uploads keep failing isn't shown the same pill as someone who simply has no signal
  ///
  /// In en, this message translates to:
  /// **'Sync error'**
  String get syncStatusError;

  /// Shown below the app-shell header instead of the normal offline message when the last sync attempt errored (SyncStatus.hasError)
  ///
  /// In en, this message translates to:
  /// **'Some changes failed to sync and PowerSync is retrying.'**
  String get offlineBannerErrorMessage;

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

  /// Activity detail screen app bar title (#310, FR-AC-3/5/6)
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get activityDetailTitle;

  /// Section header above an activity's per-type attributes on the detail screen (#310)
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get activityDetailAttributesHeader;

  /// Visible field label preceding an activity's performer on the detail screen (#310, FR-TEN-2)
  ///
  /// In en, this message translates to:
  /// **'Performed by'**
  String get activityPerformedByLabel;

  /// Edit FAB label on the activity detail screen (#310, FR-AC-3)
  ///
  /// In en, this message translates to:
  /// **'Edit activity'**
  String get editActivityAction;

  /// App bar title for the activity edit form, reached from the detail screen (#310, FR-AC-3)
  ///
  /// In en, this message translates to:
  /// **'Edit activity'**
  String get editActivityTitle;

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

  /// Display label for the harvest activity type (#38, FR-AC-1)
  ///
  /// In en, this message translates to:
  /// **'Honey harvest'**
  String get activityTypeHarvestLabel;

  /// Display label for the feeding activity type (#38, FR-AC-1)
  ///
  /// In en, this message translates to:
  /// **'Feeding'**
  String get activityTypeFeedingLabel;

  /// Display label for the treatment activity type (#38, FR-AC-1)
  ///
  /// In en, this message translates to:
  /// **'Treatment'**
  String get activityTypeTreatmentLabel;

  /// Display label for the generic (date + notes only) activity type (#38, FR-AC-1)
  ///
  /// In en, this message translates to:
  /// **'Generic'**
  String get activityTypeGenericLabel;

  /// Display label for a treatment with no disease tied to it (#38, FR-AC-1, D-19)
  ///
  /// In en, this message translates to:
  /// **'General / preventive'**
  String get treatmentContextGeneralLabel;

  /// Display label for a treatment tied to a named disease/condition (#38, FR-AC-1, D-19)
  ///
  /// In en, this message translates to:
  /// **'Specific disease/condition'**
  String get treatmentContextDiseaseSpecificLabel;

  /// Display label for a disease-detection report with no treatment applied yet (#38, FR-AC-1, D-19)
  ///
  /// In en, this message translates to:
  /// **'Detection only (no treatment yet)'**
  String get treatmentContextDetectionOnlyLabel;

  /// Screen header title for the add-activity form (#39, FR-AC-2)
  ///
  /// In en, this message translates to:
  /// **'Add activity'**
  String get newActivityTitle;

  /// Button on the apiary detail page that opens the add-activity form (#39, FR-AC-2)
  ///
  /// In en, this message translates to:
  /// **'Add activity'**
  String get addActivityAction;

  /// Field label for the activity-type selector on the add-activity form (#39, FR-AC-2)
  ///
  /// In en, this message translates to:
  /// **'Activity type'**
  String get activityTypeFieldLabel;

  /// Field label for an activity's date on the add-activity form (#39, FR-AC-2)
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get activityOccurredAtLabel;

  /// Field label for the harvest activity's honey_supers attribute — the primary yield metric (#38/#39, FR-AC-1)
  ///
  /// In en, this message translates to:
  /// **'Honey supers harvested'**
  String get activityHoneySupersLabel;

  /// Field label for the harvest activity's optional honey_kg attribute (#38/#39, FR-AC-1)
  ///
  /// In en, this message translates to:
  /// **'Honey harvested (kg)'**
  String get activityHoneyKgLabel;

  /// Field label for the optional hives_involved attribute shared by harvest/feeding/treatment (#38/#39, FR-AC-1, D-2)
  ///
  /// In en, this message translates to:
  /// **'Hives involved'**
  String get activityHivesInvolvedLabel;

  /// Field label for the feeding activity's feed_type attribute (#38/#39, FR-AC-1)
  ///
  /// In en, this message translates to:
  /// **'Feed type'**
  String get activityFeedTypeLabel;

  /// Field label for the feeding activity's feed_amount attribute (#38/#39, FR-AC-1)
  ///
  /// In en, this message translates to:
  /// **'Feed amount'**
  String get activityFeedAmountLabel;

  /// Field label for the treatment activity's treatment_context selector (#38/#39, FR-AC-1, D-19)
  ///
  /// In en, this message translates to:
  /// **'Treatment context'**
  String get activityTreatmentContextFieldLabel;

  /// Field label for the treatment activity's treatment_type attribute (#38/#39, FR-AC-1)
  ///
  /// In en, this message translates to:
  /// **'Treatment product'**
  String get activityTreatmentTypeLabel;

  /// Field label for the treatment activity's conditionally-required disease attribute (#38/#39, FR-AC-1, D-19)
  ///
  /// In en, this message translates to:
  /// **'Disease / condition'**
  String get activityDiseaseLabel;

  /// Helper text shown under the treatment_type field once the detection-only context is selected, clarifying it isn't required (#291 AC: a detection can be logged with no treatment applied yet)
  ///
  /// In en, this message translates to:
  /// **'Optional for a detection-only report'**
  String get activityTreatmentTypeOptionalForDetectionHint;

  /// Field label for the harvest activity's optional lot_batch attribute (#292, FR-AC-1, D-19)
  ///
  /// In en, this message translates to:
  /// **'Lot / batch identifier'**
  String get activityLotBatchLabel;

  /// Field label for an activity's free-text notes attribute, shared by every type (#38/#39, FR-AC-1)
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get activityNotesLabel;

  /// Validation message for a required activity attribute left empty (#39, FR-AC-2 AC: required attributes are validated before save)
  ///
  /// In en, this message translates to:
  /// **'This field is required'**
  String get activityFieldRequired;

  /// Generic validation message for an activity attribute the client-side mirror (activity_attributes.dart) rejects for a reason other than being required (#39)
  ///
  /// In en, this message translates to:
  /// **'This value isn\'t valid'**
  String get activityFieldInvalid;

  /// Confirmation toast after successfully saving a new activity, offline or online (#39, FR-OF-1)
  ///
  /// In en, this message translates to:
  /// **'Activity saved'**
  String get activitySaveSuccess;

  /// Error toast when saving a new activity throws (#39)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the activity: {error}'**
  String activitySaveError(String error);

  /// Empty state on the apiary detail page's activities section when the apiary has no activities at all yet (#42, FR-AC-5)
  ///
  /// In en, this message translates to:
  /// **'No activities logged for this apiary yet.'**
  String get apiaryActivitiesEmpty;

  /// Action at the foot of the apiary detail page's activities preview when it is capped — opens the full per-apiary activities list (#42, FR-AC-5). {count} is the total number of activities matching the current filters.
  ///
  /// In en, this message translates to:
  /// **'View all {count} activities'**
  String apiaryActivitiesViewAll(int count);

  /// Empty state on the main Activities tab when the organization has no activities at all yet (#43, FR-AC-6)
  ///
  /// In en, this message translates to:
  /// **'No activities yet.'**
  String get activitiesEmpty;

  /// Shown instead of the plain empty state when type/date-range filters are active but match nothing (#42/#43 AC: combined filters + empty/no-results state)
  ///
  /// In en, this message translates to:
  /// **'No activities match your filters.'**
  String get activitiesFilterNoResults;

  /// Error state on an activities list (#42/#43)
  ///
  /// In en, this message translates to:
  /// **'Could not load activities: {error}'**
  String activitiesError(String error);

  /// Field label for the activity-type filter dropdown (#42/#43, FR-AC-5/FR-AC-6)
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get activityFilterTypeLabel;

  /// The activity-type filter's cleared/default option — no type filter applied (#42/#43)
  ///
  /// In en, this message translates to:
  /// **'All types'**
  String get activityFilterTypeAll;

  /// Field label for the date-range filter control (#42/#43, FR-AC-5/FR-AC-6)
  ///
  /// In en, this message translates to:
  /// **'Date range'**
  String get activityFilterDateRangeLabel;

  /// The date-range filter's cleared/default state — no date filter applied (#42/#43)
  ///
  /// In en, this message translates to:
  /// **'Any date'**
  String get activityFilterDateRangeUnset;

  /// The selected date range, both bounds already locale-formatted by the caller (#42/#43)
  ///
  /// In en, this message translates to:
  /// **'{start} – {end}'**
  String activityFilterDateRangeValue(String start, String end);

  /// Button that resets both the type and date-range filters at once (#42/#43)
  ///
  /// In en, this message translates to:
  /// **'Clear filters'**
  String get activityFilterClearAction;

  /// Attribution shown on an activity performed by the current caller (#44, FR-TEN-2) — matches the map screen's own 'You' marker label (apiaryMapUserLocationLabel) for consistency
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get activityPerformedByYou;

  /// Attribution shown on an activity performed by another org member, identified by a short id fragment — there is no member-display-name lookup available anywhere in the app for a non-admin caller (#44, see activity_display.dart's doc comment)
  ///
  /// In en, this message translates to:
  /// **'Member {id}'**
  String activityPerformedByMember(String id);

  /// Fallback attribution for the brief local-only window before a freshly-created activity round-trips through sync and performed_by is populated server-side (#44)
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get activityPerformedByUnknown;

  /// Screen-reader label wrapping an activity row's attribution chip (#44, WCAG 2.2 AA)
  ///
  /// In en, this message translates to:
  /// **'Performed by: {who}'**
  String activityPerformedBySemanticLabel(String who);

  /// Fallback list-row summary for an activity with no type-specific attributes to show (e.g. a generic activity with no notes) (#42/#43)
  ///
  /// In en, this message translates to:
  /// **'No additional details'**
  String get activityNoAttributesSummary;

  /// Error toast when loading an existing activity for editing throws (#40)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load the activity: {error}'**
  String activityLoadError(String error);

  /// Destructive button on the edit-activity form that opens the delete confirmation dialog (#41, FR-AC-4)
  ///
  /// In en, this message translates to:
  /// **'Delete activity'**
  String get deleteActivity;

  /// Confirmation toast after successfully deleting an activity, offline or online (#41, FR-OF-1)
  ///
  /// In en, this message translates to:
  /// **'Activity deleted'**
  String get activityDeleteSuccess;

  /// Error toast when deleting an activity throws (#41)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t delete the activity: {error}'**
  String activityDeleteError(String error);

  /// Title of the confirmation dialog shown before deleting an activity (#41 AC: a confirmation step to prevent accidental deletion)
  ///
  /// In en, this message translates to:
  /// **'Delete activity?'**
  String get deleteActivityConfirmTitle;

  /// Body of the confirmation dialog shown before deleting an activity (#41)
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes this activity. This cannot be undone.'**
  String get deleteActivityConfirmMessage;

  /// Confirm action in the delete-activity confirmation dialog (#41)
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteActivityConfirmAction;

  /// Cancel action in the delete-activity confirmation dialog (#41 AC: cancel is a no-op)
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get deleteActivityCancelAction;

  /// Floating action button to create a journey (#45, FR-JO-4)
  ///
  /// In en, this message translates to:
  /// **'New journey'**
  String get addJourney;

  /// Create form app bar title (#45)
  ///
  /// In en, this message translates to:
  /// **'New journey'**
  String get newJourneyTitle;

  /// Edit form app bar title (#45)
  ///
  /// In en, this message translates to:
  /// **'Edit journey'**
  String get editJourneyTitle;

  /// Empty state on the main Journeys tab when the organization has no journeys at all yet (#45, FR-JO-4)
  ///
  /// In en, this message translates to:
  /// **'No journeys yet. Tap “New journey” to create one.'**
  String get journeysEmpty;

  /// Error state on the Journeys tab (#45)
  ///
  /// In en, this message translates to:
  /// **'Could not load journeys: {error}'**
  String journeysError(String error);

  /// Shown instead of the plain empty state when date-range/activity-type filters are active but match nothing (#47 AC: combined filters + empty/no-results state)
  ///
  /// In en, this message translates to:
  /// **'No journeys match your filters.'**
  String get journeysFilterNoResults;

  /// Field label for the Journeys tab's activity-type filter dropdown (#47, FR-JO-2)
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get journeyFilterTypeLabel;

  /// The Journeys tab's activity-type filter's cleared/default option — no type filter applied (#47)
  ///
  /// In en, this message translates to:
  /// **'All types'**
  String get journeyFilterTypeAll;

  /// Field label for the Journeys tab's date-range filter control (#47, FR-JO-2)
  ///
  /// In en, this message translates to:
  /// **'Date range'**
  String get journeyFilterDateRangeLabel;

  /// The Journeys tab's date-range filter's cleared/default state — no date filter applied (#47)
  ///
  /// In en, this message translates to:
  /// **'Any date'**
  String get journeyFilterDateRangeUnset;

  /// The Journeys tab's selected date range, both bounds already locale-formatted by the caller (#47)
  ///
  /// In en, this message translates to:
  /// **'{start} – {end}'**
  String journeyFilterDateRangeValue(String start, String end);

  /// Button that resets both the Journeys tab's type and date-range filters at once (#47)
  ///
  /// In en, this message translates to:
  /// **'Clear filters'**
  String get journeyFilterClearAction;

  /// Per-row plan-vs-done progress badge on the Journeys tab (#47, FR-JO-2 — 'feitos/planeados'): how many of the journey's planned apiaries already have a matching recorded activity, out of the total planned. Only shown when planned > 0.
  ///
  /// In en, this message translates to:
  /// **'{done}/{planned} apiaries visited'**
  String journeyProgressBadge(int done, int planned);

  /// Field label for a journey's name on the create/edit form (#45, FR-JO-4)
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get journeyNameLabel;

  /// Validation message when a journey's name is left empty (#45)
  ///
  /// In en, this message translates to:
  /// **'Name is required'**
  String get journeyNameRequired;

  /// Field label for a journey's one main activity type on the create/edit form (#45, FR-JO-4, D-21)
  ///
  /// In en, this message translates to:
  /// **'Main activity type'**
  String get journeyMainActivityTypeLabel;

  /// Section label above the apiary multi-select picker on the journey create/edit form (#45, FR-JO-4)
  ///
  /// In en, this message translates to:
  /// **'Apiaries to visit'**
  String get journeyApiariesLabel;

  /// Validation message when no apiary is selected for a journey's plan (#45)
  ///
  /// In en, this message translates to:
  /// **'Select at least one apiary'**
  String get journeyApiariesRequired;

  /// Shown in the apiary multi-select picker when the organization has no apiaries at all yet (#45)
  ///
  /// In en, this message translates to:
  /// **'No apiaries yet — add one from the Apiaries tab first.'**
  String get journeyApiariesNoneAvailable;

  /// Running count below the apiary multi-select picker (#45)
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No apiaries selected} =1{1 apiary selected} other{{count} apiaries selected}}'**
  String journeyApiariesSelectedCount(int count);

  /// Error toast when loading an existing journey for editing throws (#45)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load the journey: {error}'**
  String journeyLoadError(String error);

  /// Success toast after creating or updating a journey (#45)
  ///
  /// In en, this message translates to:
  /// **'Journey saved'**
  String get journeySaveSuccess;

  /// Error toast when saving a journey throws (#45)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the journey: {error}'**
  String journeySaveError(String error);

  /// Button on the edit-journey form that closes an open journey (#45, D-21)
  ///
  /// In en, this message translates to:
  /// **'Close journey'**
  String get closeJourneyAction;

  /// Success toast after closing a journey (#45, D-21)
  ///
  /// In en, this message translates to:
  /// **'Journey closed'**
  String get journeyCloseSuccess;

  /// Error toast when closing a journey throws (#45, D-21)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t close the journey: {error}'**
  String journeyCloseError(String error);

  /// Display label for a journey's open status (#45, D-21)
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get journeyStatusOpenLabel;

  /// Display label for a journey's closed status (#45, D-21)
  ///
  /// In en, this message translates to:
  /// **'Closed'**
  String get journeyStatusClosedLabel;

  /// Screen-reader label for the journey edit form's status chip (#45, D-21)
  ///
  /// In en, this message translates to:
  /// **'Status: {label}'**
  String journeyStatusSemanticLabel(String label);

  /// Destructive button on the edit-journey form that opens the delete confirmation dialog (#45, FR-JO-4)
  ///
  /// In en, this message translates to:
  /// **'Delete journey'**
  String get deleteJourney;

  /// Success toast after deleting a journey (#45)
  ///
  /// In en, this message translates to:
  /// **'Journey deleted'**
  String get journeyDeleteSuccess;

  /// Error toast when deleting a journey throws (#45)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t delete the journey: {error}'**
  String journeyDeleteError(String error);

  /// Title of the confirmation dialog shown before deleting a journey (#45, mirrors deleteActivityConfirmTitle)
  ///
  /// In en, this message translates to:
  /// **'Delete journey?'**
  String get deleteJourneyConfirmTitle;

  /// Body of the confirmation dialog shown before deleting a journey (#45)
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes this journey. This cannot be undone.'**
  String get deleteJourneyConfirmMessage;

  /// Confirm action in the delete-journey confirmation dialog (#45)
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteJourneyConfirmAction;

  /// Cancel action in the delete-journey confirmation dialog (#45 AC: cancel is a no-op)
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get deleteJourneyCancelAction;

  /// Section label above the journey attachment summary on the add-activity form (#46, FR-JO-1, D-21)
  ///
  /// In en, this message translates to:
  /// **'Journey'**
  String get journeyAttachmentLabel;

  /// Shown in the journey attachment summary when no journey is currently selected (either an auto-match miss, or the user explicitly deselected) (#46)
  ///
  /// In en, this message translates to:
  /// **'No journey attached'**
  String get journeyAttachmentNone;

  /// Small hint shown under the attached journey's name when it was auto-selected by the app (not explicitly chosen by the user) (#46, FR-JO-1, D-21)
  ///
  /// In en, this message translates to:
  /// **'Auto-selected — matches this apiary and activity type'**
  String get journeyAttachmentAutoSelectedHint;

  /// Button that opens the journey picker to switch/select a journey on the add-activity form (#46)
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get journeyAttachmentChangeAction;

  /// Button that deselects the currently-attached journey on the add-activity form (#46 AC: the user can deselect the pre-filled journey)
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get journeyAttachmentRemoveAction;

  /// Title of the journey picker bottom sheet (#46)
  ///
  /// In en, this message translates to:
  /// **'Choose a journey'**
  String get journeyPickerTitle;

  /// Error state inside the journey picker bottom sheet (#46)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load journeys: {error}'**
  String journeyPickerError(String error);

  /// The explicit "no journey" option, always the first row in the journey picker (#46 AC: the user can deselect the pre-filled journey)
  ///
  /// In en, this message translates to:
  /// **'No journey'**
  String get journeyPickerNoneOption;

  /// Shown in the journey picker when there are no open matching journeys to list (auto-match miss) and "show hidden journeys" is off (#46)
  ///
  /// In en, this message translates to:
  /// **'No open journeys match this apiary and activity type yet.'**
  String get journeyPickerNoOpenMatches;

  /// Toggle in the journey picker that reveals closed matching journeys, normally hidden by default (#46, D-21)
  ///
  /// In en, this message translates to:
  /// **'Show hidden journeys'**
  String get journeyPickerShowHiddenToggle;

  /// Screen-reader label for a closed journey's row in the picker, once revealed via the show-hidden toggle (#46, D-21)
  ///
  /// In en, this message translates to:
  /// **'{name}, closed journey'**
  String journeyPickerClosedOptionSemanticLabel(String name);

  /// The inline create-new-journey shortcut row at the bottom of the journey picker (#46 AC)
  ///
  /// In en, this message translates to:
  /// **'Create a new journey'**
  String get journeyPickerCreateNewAction;

  /// Title of the inline quick-create-journey bottom sheet, opened from the journey picker (#46 AC)
  ///
  /// In en, this message translates to:
  /// **'New journey'**
  String get journeyQuickCreateTitle;

  /// Cancel action on the inline quick-create-journey sheet — closes it without creating anything (#46)
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get journeyQuickCreateCancelAction;

  /// Title of the confirm-to-proceed dialog shown when saving an activity against a closed journey (#46 AC, D-21)
  ///
  /// In en, this message translates to:
  /// **'This journey is closed'**
  String get closedJourneyConfirmTitle;

  /// Body of the confirm-to-proceed dialog shown when saving an activity against a closed journey (#46 AC: "this journey is closed — add anyway?")
  ///
  /// In en, this message translates to:
  /// **'\"{journeyName}\" is closed. Add this activity to it anyway?'**
  String closedJourneyConfirmMessage(String journeyName);

  /// Cancel action in the closed-journey confirm dialog — stays on the form, nothing is saved (#46)
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get closedJourneyConfirmCancelAction;

  /// Confirm action in the closed-journey confirm dialog — proceeds with saving the activity against the closed journey (#46 AC)
  ///
  /// In en, this message translates to:
  /// **'Add anyway'**
  String get closedJourneyConfirmAddAction;

  /// Heading above the journey stats section (#49, FR-JO-1) — apiaries visited, hives harvested, honey collected, média alças/colmeia
  ///
  /// In en, this message translates to:
  /// **'Journey stats'**
  String get journeyStatsSectionTitle;

  /// Error state when loading a journey's aggregated stats throws (#49)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load journey stats: {error}'**
  String journeyStatsError(String error);

  /// Stat card label for the apiaries-visited-vs-planned metric (#49, FR-JO-1), matching the Melargil prototype's "apiários visitados" card
  ///
  /// In en, this message translates to:
  /// **'Apiaries visited'**
  String get journeyStatsApiariesVisitedLabel;

  /// Value shown on the apiaries-visited stat card, e.g. "3/5" (#49, FR-JO-1)
  ///
  /// In en, this message translates to:
  /// **'{done}/{planned}'**
  String journeyStatsApiariesVisitedValue(int done, int planned);

  /// Stat card label for Σ hives_involved across the journey's harvest activities (#49, D-2), matching the prototype's "colmeias trabalhadas" card
  ///
  /// In en, this message translates to:
  /// **'Hives harvested'**
  String get journeyStatsHivesHarvestedLabel;

  /// Stat card label for Σ honey_kg across the journey's harvest activities (#49), matching the prototype's "mel colhido" card
  ///
  /// In en, this message translates to:
  /// **'Honey collected'**
  String get journeyStatsHoneyCollectedLabel;

  /// Value shown on the honey-collected stat card, e.g. "12.5 kg" — kg is already locale-formatted by the caller (LocaleFormatting) (#49)
  ///
  /// In en, this message translates to:
  /// **'{kg} kg'**
  String journeyStatsHoneyCollectedValue(String kg);

  /// Stat card label for Σ honey_supers ÷ Σ hives_involved across the journey's harvest activities (#49) — kept in Portuguese per the prototype/AC's own naming (docs/design/prototype.md's Q-JOUR answer, this issue's own AC wording), not translated to an English equivalent
  ///
  /// In en, this message translates to:
  /// **'Média alças/colmeia'**
  String get journeyStatsAverageSupersLabel;

  /// Shown instead of a number on the média alças/colmeia stat card when there is no hive-count denominator yet — zero harvest activities, or every one has a null/zero hives_involved (#49, NFR-TST-1's no-divide-by-zero case)
  ///
  /// In en, this message translates to:
  /// **'No data yet'**
  String get journeyStatsAverageSupersNoData;

  /// Summary line below the stat cards showing how many planned apiaries have no matching activity yet (#49, FR-JO-1: "how much is still missing, planned vs. done")
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{All planned apiaries visited} =1{1 apiary still missing} other{{count} apiaries missing}}'**
  String journeyStatsMissingLabel(int count);

  /// Shell app bar title for the journey detail route (#48, FR-JO-3) — a generic, not per-instance, title mirroring apiaryDetailTitle/activityDetailTitle's own convention; the specific journey's name renders in the page body itself
  ///
  /// In en, this message translates to:
  /// **'Journey'**
  String get journeyDetailTitle;

  /// Floating action button on the journey detail page that opens the existing edit form (#48) — mirrors editApiaryAction
  ///
  /// In en, this message translates to:
  /// **'Edit journey'**
  String get editJourneyAction;

  /// Section heading above the journey detail page's per-apiary list (#48, FR-JO-3)
  ///
  /// In en, this message translates to:
  /// **'Apiaries'**
  String get journeyDetailApiariesTitle;

  /// Placeholder apiary card title when an activity's apiary_id can't be resolved against the currently-loaded apiary list — e.g. the apiary was deleted since, or apiariesStreamProvider hasn't emitted yet (#48) — never a raw internal id
  ///
  /// In en, this message translates to:
  /// **'Unknown apiary'**
  String get journeyDetailApiaryNameUnknown;

  /// Badge on a journey detail apiary card once it has at least one activity attributed to this journey via the stored journey_id (#48 AC: planned vs. actual)
  ///
  /// In en, this message translates to:
  /// **'Visited'**
  String get journeyDetailApiaryVisitedBadge;

  /// Badge on a journey detail apiary card that's in the journey's plan but has no attributed activity yet (#48 AC: planned vs. actual)
  ///
  /// In en, this message translates to:
  /// **'Planned'**
  String get journeyDetailApiaryPlannedBadge;

  /// Placeholder shown under a planned-only apiary card on the journey detail page, in place of an activity list (#48 AC: planned items clearly distinguished from completed ones)
  ///
  /// In en, this message translates to:
  /// **'Not visited yet'**
  String get journeyDetailApiaryNotVisitedYet;

  /// Empty state on the journey detail page's apiaries section — the edge case of a journey with no plan and no attributed activities (#48)
  ///
  /// In en, this message translates to:
  /// **'No apiaries in this journey yet.'**
  String get journeyDetailApiariesEmpty;

  /// Empty state on the main Todos tab when the organization has no todos at all yet (#53, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'No todos yet.'**
  String get todosEmpty;

  /// Shown instead of the plain empty state when status/priority/due-date filters are active but match nothing (#53 AC: combined filters + empty/no-results state)
  ///
  /// In en, this message translates to:
  /// **'No todos match your filters.'**
  String get todosFilterNoResults;

  /// Error state on the main Todos tab (#53)
  ///
  /// In en, this message translates to:
  /// **'Could not load todos: {error}'**
  String todosError(String error);

  /// Field label for the Todos tab's status filter dropdown (#53, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get todoFilterStatusLabel;

  /// The status filter's cleared/default option — no status filter applied (#53)
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get todoFilterStatusAll;

  /// Status filter option / status word for a todo that is neither done nor overdue (#53 AC: distinguishes open, completed, overdue)
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get todoFilterStatusOpen;

  /// Status filter option / status word for an open todo whose due date has passed (#53 AC: overdue, feeds FR-AI-1's later "overdue todos" example)
  ///
  /// In en, this message translates to:
  /// **'Overdue'**
  String get todoFilterStatusOverdue;

  /// Status filter option / status word for a done todo — the display label for the underlying 'done' status value (#50/#53)
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get todoFilterStatusDone;

  /// Field label for the Todos tab's priority filter dropdown (#53, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'Priority'**
  String get todoFilterPriorityLabel;

  /// The priority filter's cleared/default option — no priority filter applied (#53)
  ///
  /// In en, this message translates to:
  /// **'All priorities'**
  String get todoFilterPriorityAll;

  /// Display label for the 'low' todo priority level (#50/#53, D-20)
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get todoPriorityLowLabel;

  /// Display label for the 'medium' todo priority level (#50/#53, D-20)
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get todoPriorityMediumLabel;

  /// Display label for the 'high' todo priority level (#50/#53, D-20)
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get todoPriorityHighLabel;

  /// Field label for the Todos tab's due-date filter dropdown (#53, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'Due'**
  String get todoFilterDueLabel;

  /// The due-date filter's cleared/default option — no due-date filter applied (#53)
  ///
  /// In en, this message translates to:
  /// **'Any date'**
  String get todoFilterDueAny;

  /// Due-date filter preset matching todos due today (#53)
  ///
  /// In en, this message translates to:
  /// **'Due today'**
  String get todoFilterDueToday;

  /// Due-date filter preset matching todos due within the current calendar week, Monday–Sunday (#53, feeds FR-AI-1's later "due in the next week" example)
  ///
  /// In en, this message translates to:
  /// **'Due this week'**
  String get todoFilterDueThisWeek;

  /// Due-date filter preset matching todos due within the current calendar month (#53)
  ///
  /// In en, this message translates to:
  /// **'Due this month'**
  String get todoFilterDueThisMonth;

  /// Button that resets the status/priority/due-date filters at once, without touching the sort selection (#53, mirrors activityFilterClearAction)
  ///
  /// In en, this message translates to:
  /// **'Clear filters'**
  String get todoFilterClearAction;

  /// Field label for the Todos tab's sort-field dropdown (#53 AC: sortable by due date, priority, and status)
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get todoSortFieldLabel;

  /// Sort-field option: order by due date (#53)
  ///
  /// In en, this message translates to:
  /// **'Due date'**
  String get todoSortFieldDueDate;

  /// Sort-field option: order by priority level (#53)
  ///
  /// In en, this message translates to:
  /// **'Priority'**
  String get todoSortFieldPriority;

  /// Sort-field option: order by lifecycle status — overdue, then open, then completed (#53)
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get todoSortFieldStatus;

  /// Current sort direction — also the direction-toggle button's tooltip/semantic label while ascending is active (#53)
  ///
  /// In en, this message translates to:
  /// **'Ascending'**
  String get todoSortDirectionAscendingLabel;

  /// Current sort direction — also the direction-toggle button's tooltip/semantic label while descending is active (#53)
  ///
  /// In en, this message translates to:
  /// **'Descending'**
  String get todoSortDirectionDescendingLabel;

  /// Shown in a todo row's subtitle in place of a formatted date when the todo has no due date (#53)
  ///
  /// In en, this message translates to:
  /// **'No due date'**
  String get todoDueDateUnset;

  /// Text of the overdue badge on a todo row — paired with a warning icon, never color alone (#53 AC, WCAG 2.2 AA 1.4.1)
  ///
  /// In en, this message translates to:
  /// **'Overdue'**
  String get todoOverdueBadge;

  /// Screen-reader label for a todo row's leading status icon — an open (not overdue, not done) row has no other visible status text (#53, WCAG 2.2 AA). {status} is one of todoFilterStatusOpen/Overdue/Done, already localized.
  ///
  /// In en, this message translates to:
  /// **'Status: {status}'**
  String todoStatusSemanticLabel(String status);

  /// Floating action button label to quick-create a todo (#52, FR-TD-1) — shown on the Todos tab's own FAB, the Apiaries tab's secondary FAB, and the apiary detail page's add-todo action
  ///
  /// In en, this message translates to:
  /// **'New todo'**
  String get addTodo;

  /// Heading of the quick-create bottom sheet (#52, FR-TD-1, FR-UX-1)
  ///
  /// In en, this message translates to:
  /// **'New todo'**
  String get todoQuickCreateTitle;

  /// Field label for the optional due-date picker on the quick-create sheet (#52, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'Due date'**
  String get todoDueDateLabel;

  /// Read-only chip on the quick-create sheet showing the apiary this todo will be associated with when opened contextually from the apiary detail page or the apiaries list (#52, FR-UX-2) — quick-create has no apiary picker of its own, the association comes entirely from context.
  ///
  /// In en, this message translates to:
  /// **'For {apiaryName}'**
  String todoQuickCreateForApiary(String apiaryName);

  /// Cancel button on the quick-create sheet — discards the in-progress todo without creating it (#52)
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get todoQuickCreateCancelAction;

  /// Success toast shown after a quick-created todo saves (#52)
  ///
  /// In en, this message translates to:
  /// **'Todo created'**
  String get todoCreatedConfirmation;

  /// Header title for the standalone todo-create route (#293) — reachable by direct navigation/deep-linking, distinct from #52's own quick-create sheet
  ///
  /// In en, this message translates to:
  /// **'New todo'**
  String get newTodoTitle;

  /// Header title for the todo detail route (#293, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'Todo'**
  String get todoDetailTitle;

  /// Header title for the todo edit route (#293, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'Edit todo'**
  String get editTodoTitle;

  /// Label of the todo detail screen's edit FAB, routing to the edit form (#293)
  ///
  /// In en, this message translates to:
  /// **'Edit todo'**
  String get editTodoAction;

  /// Field label for a todo's required title, on the create/edit form (#293, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get todoTitleLabel;

  /// Validation message when a todo's title is left blank on save (#293)
  ///
  /// In en, this message translates to:
  /// **'Title is required'**
  String get todoTitleRequired;

  /// Field label for a todo's optional free-text description, on the form and the detail screen (#293, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get todoDescriptionLabel;

  /// Fallback shown on the todo detail screen when the todo has no description (#293)
  ///
  /// In en, this message translates to:
  /// **'No description'**
  String get todoDescriptionUnset;

  /// Field label for a todo's optional due date, on the form and the detail screen (#293, FR-TD-1) — due dates may be in the future, unlike an activity's occurred-at date
  ///
  /// In en, this message translates to:
  /// **'Due date'**
  String get todoDueDateFieldLabel;

  /// Tooltip/semantic label for the icon button that clears a set due date on the todo form (#293)
  ///
  /// In en, this message translates to:
  /// **'Clear due date'**
  String get todoDueDateClearAction;

  /// Field label for a todo's priority dropdown, on the form and the detail screen (#293, FR-TD-1, D-20) — distinct from todoFilterPriorityLabel, the Todos tab's own filter dropdown
  ///
  /// In en, this message translates to:
  /// **'Priority'**
  String get todoPriorityFieldLabel;

  /// Field label for a todo's assignee picker, on the form and the detail screen (#293, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'Assignee'**
  String get todoAssigneeFieldLabel;

  /// Field label for a todo's apiary-association picker, on the form and the detail screen (#293, #51, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'Apiary'**
  String get todoApiaryFieldLabel;

  /// The assignee picker's clear row label, and the detail screen's fallback when a todo has no assignee (#293, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'Unassigned'**
  String get todoAssigneeUnassigned;

  /// Fallback label for an assignee id not (yet) resolvable to a real name — offline, pre-first-fetch, or a removed member (#293, mirrors activityPerformedByMember). {id} is a short, non-spoofable id fragment, not the full id.
  ///
  /// In en, this message translates to:
  /// **'Member {id}'**
  String todoAssigneeUnknown(String id);

  /// Shown in the assignee picker when the org member roster hasn't loaded yet (offline / pre-first-fetch) — the Unassigned clear row still renders alongside this (#293)
  ///
  /// In en, this message translates to:
  /// **'No members available yet.'**
  String get todoAssigneeNoneAvailable;

  /// The apiary picker's clear row label, and the detail screen's fallback for a general, org-level todo with no apiary association (#293, #51, FR-TD-1)
  ///
  /// In en, this message translates to:
  /// **'No apiary'**
  String get todoApiaryNone;

  /// Fallback label on the todo detail screen for an apiary id no longer in the locally-synced apiary set — a stale reference to a since-deleted apiary (#293, mirrors todos_repository.dart's own doc comment on this exact case)
  ///
  /// In en, this message translates to:
  /// **'Unknown apiary'**
  String get todoApiaryUnknown;

  /// Heading above the todo detail screen's read-only field list (#293, mirrors activityDetailAttributesHeader)
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get todoDetailFieldsHeader;

  /// Detail-screen row label for a done todo's completion timestamp (#293) — worded distinctly from the plain status word todoFilterStatusDone ("Completed") so the two never collide on the same screen
  ///
  /// In en, this message translates to:
  /// **'Completed at'**
  String get todoCompletedAtLabel;

  /// Label of the complete/reopen toggle button while the todo is open (#293, FR-TD-1) — on both the detail screen and the form
  ///
  /// In en, this message translates to:
  /// **'Mark as complete'**
  String get todoCompleteAction;

  /// Label of the complete/reopen toggle button while the todo is done (#293, FR-TD-1) — on both the detail screen and the form
  ///
  /// In en, this message translates to:
  /// **'Reopen'**
  String get todoReopenAction;

  /// Success toast after completing a todo via the toggle (#293)
  ///
  /// In en, this message translates to:
  /// **'Todo marked complete'**
  String get todoCompleteSuccess;

  /// Error toast when completing a todo fails (#293)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t update the todo: {error}'**
  String todoCompleteError(String error);

  /// Success toast after reopening a todo via the toggle (#293)
  ///
  /// In en, this message translates to:
  /// **'Todo reopened'**
  String get todoReopenSuccess;

  /// Error toast when reopening a todo fails (#293)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t update the todo: {error}'**
  String todoReopenError(String error);

  /// Success toast after creating or editing a todo (#293, mirrors activitySaveSuccess's own create-and-update-share-one-message precedent)
  ///
  /// In en, this message translates to:
  /// **'Todo saved'**
  String get todoSaveSuccess;

  /// Error toast when creating or editing a todo fails (#293)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the todo: {error}'**
  String todoSaveError(String error);

  /// Error toast when the edit form's initial load of an existing todo fails (#293)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load the todo: {error}'**
  String todoLoadError(String error);

  /// Label of the delete button on the todo form (#293 AC: delete the todo from the form)
  ///
  /// In en, this message translates to:
  /// **'Delete todo'**
  String get deleteTodo;

  /// Success toast after deleting a todo (#293)
  ///
  /// In en, this message translates to:
  /// **'Todo deleted'**
  String get todoDeleteSuccess;

  /// Error toast when deleting a todo fails (#293)
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t delete the todo: {error}'**
  String todoDeleteError(String error);

  /// Title of the delete-confirmation dialog on the todo form (#293)
  ///
  /// In en, this message translates to:
  /// **'Delete todo?'**
  String get deleteTodoConfirmTitle;

  /// Body of the delete-confirmation dialog on the todo form (#293)
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes this todo. This cannot be undone.'**
  String get deleteTodoConfirmMessage;

  /// Confirm action of the todo delete-confirmation dialog (#293)
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteTodoConfirmAction;

  /// Cancel action of the todo delete-confirmation dialog (#293) — always a no-op
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get deleteTodoCancelAction;

  /// Header of the per-entity change-history timeline section on an apiary/activity detail screen (#60, FR-HIS-1)
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get historySectionTitle;

  /// App-bar title of the full per-entity history screen reached from the detail-screen section's view-all link (#60, FR-HIS-1)
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get historyScreenTitle;

  /// Empty state of the history timeline (#60) — also what an offline device with no synced history slice shows, which is a legitimate empty result, not an error
  ///
  /// In en, this message translates to:
  /// **'No changes recorded yet'**
  String get historyEmpty;

  /// Error state of the history timeline (#60)
  ///
  /// In en, this message translates to:
  /// **'Could not load history: {error}'**
  String historyError(String error);

  /// Link from the capped history section on a detail screen to the full history screen (#60) — mirrors the activities section's own view-all affordance (#42)
  ///
  /// In en, this message translates to:
  /// **'View all'**
  String get historyViewAllAction;

  /// Timeline label for an audit_log change_type=create row (#60, history.md §3)
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get historyEventCreated;

  /// Timeline label for an audit_log change_type=update row (#60, history.md §3)
  ///
  /// In en, this message translates to:
  /// **'Updated'**
  String get historyEventUpdated;

  /// Timeline label for an audit_log change_type=delete row — a soft-delete tombstone (#60, history.md §3)
  ///
  /// In en, this message translates to:
  /// **'Deleted'**
  String get historyEventDeleted;

  /// Timeline label for a sync_conflict_log row: an offline edit that lost last-write-wins and was preserved rather than dropped (#60, history.md §6)
  ///
  /// In en, this message translates to:
  /// **'Superseded'**
  String get historyEventSuperseded;

  /// Fallback timeline label for an event kind this client version doesn't recognize (#60) — the vocabulary is extensible server-side (D-20), so an unknown kind degrades to a generic label instead of breaking the timeline
  ///
  /// In en, this message translates to:
  /// **'Changed'**
  String get historyEventUnknown;

  /// Sub-line of an update entry listing which fields changed (#60) — fields is already localized and comma-joined by the caller
  ///
  /// In en, this message translates to:
  /// **'Changed: {fields}'**
  String historyChangedFieldsValue(String fields);

  /// Sub-line of a superseded entry (#60, history.md §6 'your offline change was superseded by a newer value') — explains that the edit was kept in the record, not lost
  ///
  /// In en, this message translates to:
  /// **'Replaced by a newer version from another device'**
  String get historySupersededDetail;

  /// History-entry actor when it is the signed-in user (#60) — mirrors activityPerformedByYou
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get historyActorYou;

  /// History-entry actor fallback when the org roster has no display name for the user id (#60) — mirrors activityPerformedByMember; id is a short trailing id fragment
  ///
  /// In en, this message translates to:
  /// **'Member {id}'**
  String historyActorMember(String id);

  /// History-entry actor when the row carries no actor_user_id at all (#60) — history.md §3 allows a null actor
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get historyActorUnknown;

  /// Screen-reader label for one history timeline entry (#60, WCAG 2.2 AA) — collapses the visually-separate event/actor/time into one announcement; all three parts are already localized and formatted by the caller
  ///
  /// In en, this message translates to:
  /// **'{event} by {actor}, {timestamp}'**
  String historyEntrySemanticLabel(
    String event,
    String actor,
    String timestamp,
  );

  /// Localized name of the apiaries.location column when it appears in an update entry's changed-fields list (#60). Columns whose user-facing name already has a form label reuse that key instead (name, notes, place_label, hive_count, occurred_at) — only the gaps get a historyField* key of their own
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get historyFieldLocation;

  /// Localized name of the activities.type column in a changed-fields list (#60)
  ///
  /// In en, this message translates to:
  /// **'Activity type'**
  String get historyFieldActivityType;

  /// Localized name of the activities.attributes column (the per-type attribute bag) in a changed-fields list (#60)
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get historyFieldAttributes;

  /// Localized name of the activities.apiary_id column in a changed-fields list (#60)
  ///
  /// In en, this message translates to:
  /// **'Apiary'**
  String get historyFieldApiary;
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
