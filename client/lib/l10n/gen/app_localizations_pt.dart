// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get appTitle => 'BeekeepingIT';

  @override
  String get homeTitle => 'Apiários';

  @override
  String get homeSubtitle =>
      'Esqueleto do fluxo — routing, tema, estado e i18n já estão ligados; os dados reais de apiário chegam com o walking skeleton.';

  @override
  String get homeOpenSampleApiaryButton => 'Ver apiário de exemplo';

  @override
  String get gatewayStatusLabel => 'Gateway';

  @override
  String get gatewayStatusChecking => 'A verificar…';

  @override
  String get gatewayStatusReachable => 'Acessível';

  @override
  String get gatewayStatusUnreachable => 'Inacessível';

  @override
  String get apiaryDetailTitle => 'Detalhe do apiário';

  @override
  String apiaryDetailBody(String id) {
    return 'Rota de detalhe placeholder para o apiário $id. O formulário real de leitura/edição chega com o walking skeleton (#23).';
  }
}
