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
  String get loginButton => 'Sign in with Keycloak';

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
}
