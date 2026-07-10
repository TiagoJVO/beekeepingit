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

  /// Admin-only app-bar action on the apiaries home, linking to the members/invitations screen (#172)
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
