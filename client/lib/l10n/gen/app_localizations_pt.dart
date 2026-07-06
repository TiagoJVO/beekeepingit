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
  String get loginPrompt => 'Inicie sessão para gerir os seus apiários.';

  @override
  String get loginButton => 'Entrar com Keycloak';

  @override
  String get logout => 'Terminar sessão';

  @override
  String get apiariesTitle => 'Apiários';

  @override
  String get apiariesEmpty =>
      'Ainda não há apiários. Toque em “Adicionar apiário” para criar um.';

  @override
  String apiariesError(String error) {
    return 'Não foi possível carregar os apiários: $error';
  }

  @override
  String get addApiary => 'Adicionar apiário';

  @override
  String hiveCountValue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count colmeias',
      one: '1 colmeia',
      zero: 'Sem colmeias',
    );
    return '$_temp0';
  }

  @override
  String get newApiaryTitle => 'Novo apiário';

  @override
  String get editApiaryTitle => 'Editar apiário';

  @override
  String get apiaryNameLabel => 'Nome';

  @override
  String get apiaryNameRequired => 'Introduza um nome.';

  @override
  String get hiveCountLabel => 'Número de colmeias';

  @override
  String get hiveCountInvalid => 'Introduza um número igual ou superior a 0.';

  @override
  String get saveButton => 'Guardar';

  @override
  String get deleteApiary => 'Eliminar apiário';
}
