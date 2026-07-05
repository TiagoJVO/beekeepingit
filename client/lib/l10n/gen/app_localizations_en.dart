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
  String get homeTitle => 'Apiaries';

  @override
  String get homeSubtitle =>
      'Walking-skeleton scaffold — routing, theming, state and i18n are wired; real apiary data lands with the walking skeleton.';

  @override
  String get homeOpenSampleApiaryButton => 'View sample apiary';

  @override
  String get gatewayStatusLabel => 'Gateway';

  @override
  String get gatewayStatusChecking => 'Checking…';

  @override
  String get gatewayStatusReachable => 'Reachable';

  @override
  String get gatewayStatusUnreachable => 'Unreachable';

  @override
  String get apiaryDetailTitle => 'Apiary detail';

  @override
  String apiaryDetailBody(String id) {
    return 'Placeholder detail route for apiary $id. The real apiary read/edit form lands with the walking skeleton (#23).';
  }
}
