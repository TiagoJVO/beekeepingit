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

  @override
  String get profileTitle => 'O seu perfil';

  @override
  String get profileOnboardingIntro =>
      'Conte-nos um pouco sobre si para começar.';

  @override
  String get profileNameLabel => 'Nome';

  @override
  String get profileNameRequired => 'Introduza o seu nome.';

  @override
  String get profileEmailLabel => 'Email';

  @override
  String get profileEmailRequired => 'Introduza o seu email.';

  @override
  String get profileEmailInvalid => 'Introduza um endereço de email válido.';

  @override
  String get profileLocaleLabel => 'Idioma preferido';

  @override
  String get profileSaveButton => 'Guardar perfil';

  @override
  String get profileSaveSuccess => 'Perfil guardado.';

  @override
  String profileSaveError(String error) {
    return 'Não foi possível guardar o seu perfil: $error';
  }

  @override
  String get organizationTitle => 'A sua organização';

  @override
  String get organizationOnboardingIntro =>
      'Crie a sua organização para começar a gerir apiários.';

  @override
  String get organizationNameLabel => 'Nome da organização';

  @override
  String get organizationNameRequired => 'Introduza o nome da organização.';

  @override
  String get organizationAddressLabel => 'Morada (opcional)';

  @override
  String get organizationSaveButton => 'Criar organização';

  @override
  String get organizationSaveSuccess => 'Organização criada.';

  @override
  String organizationSaveError(String error) {
    return 'Não foi possível criar a sua organização: $error';
  }

  @override
  String get membersTitle => 'Membros e convites';

  @override
  String membersLoadError(String error) {
    return 'Não foi possível carregar os membros: $error';
  }

  @override
  String get membersInviteEmailLabel => 'Email a convidar';

  @override
  String get membersInviteEmailRequired => 'Introduza um endereço de email.';

  @override
  String get membersInviteButton => 'Convidar';

  @override
  String get membersInviteSuccess => 'Convite enviado.';

  @override
  String membersInviteError(String error) {
    return 'Não foi possível concluir o pedido: $error';
  }

  @override
  String get membersSectionTitle => 'Membros';

  @override
  String get membersEmpty => 'Ainda não há membros.';

  @override
  String get invitationsSectionTitle => 'Convites';

  @override
  String get invitationsEmpty => 'Ainda não há convites.';

  @override
  String get membersRevokeButton => 'Revogar convite';

  @override
  String get membersRevokeSuccess => 'Convite revogado.';
}
