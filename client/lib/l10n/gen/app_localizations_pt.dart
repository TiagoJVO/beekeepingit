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
  String get loginButton => 'Iniciar sessão';

  @override
  String get loginError =>
      'Não foi possível iniciar sessão — verifique a ligação e tente novamente.';

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
  String get profileGenericError => 'Ocorreu um erro. Tente novamente.';

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
  String get membersInviteEmailInvalid =>
      'Introduza um endereço de email válido.';

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

  @override
  String get memberRoleAdmin => 'Administrador';

  @override
  String get memberRoleUser => 'Membro';

  @override
  String get memberStatusActive => 'Ativo';

  @override
  String get memberStatusInvited => 'Convidado';

  @override
  String get memberStatusRemoved => 'Removido';

  @override
  String get invitationStatusPending => 'Pendente';

  @override
  String get invitationStatusAccepted => 'Aceite';

  @override
  String get invitationStatusExpired => 'Expirado';

  @override
  String get invitationStatusRevoked => 'Revogado';

  @override
  String get membersLoadMoreButton => 'Carregar mais';

  @override
  String get manageMembers => 'Gerir membros';

  @override
  String get accountTitle => 'Definições da conta';

  @override
  String get accountProfileSectionTitle => 'Perfil';

  @override
  String get accountSecuritySectionTitle => 'Segurança';

  @override
  String get accountChangePasswordHint =>
      'As alterações de palavra-passe são geridas pelo nosso fornecedor de login, numa nova aba.';

  @override
  String get accountChangePasswordButton => 'Alterar palavra-passe';

  @override
  String get accountOrganizationSectionTitle => 'Organização';

  @override
  String get activitiesTitle => 'Atividades';

  @override
  String get journeysTitle => 'Jornadas';

  @override
  String get todosTitle => 'Tarefas';

  @override
  String get assistantTitle => 'Assistente';

  @override
  String get activitiesComingSoon => 'Atividades — brevemente';

  @override
  String get journeysComingSoon => 'Jornadas — brevemente';

  @override
  String get todosComingSoon => 'Tarefas — brevemente';

  @override
  String get assistantComingSoon => 'Assistente — brevemente';

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
    return 'Estado de sincronização: $label. Abre as definições de sincronização.';
  }

  @override
  String offlineBannerMessage(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Sem ligação — alterações guardadas localmente ($count por sincronizar)',
      one: 'Sem ligação — alterações guardadas localmente (1 por sincronizar)',
      zero: 'Sem ligação — alterações guardadas localmente',
    );
    return '$_temp0';
  }

  @override
  String get apiarySaveSuccess => 'Apiário guardado.';

  @override
  String get apiaryDeleteSuccess => 'Apiário eliminado.';

  @override
  String apiarySaveError(String error) {
    return 'Não foi possível guardar o apiário: $error';
  }

  @override
  String apiaryDeleteError(String error) {
    return 'Não foi possível eliminar o apiário: $error';
  }

  @override
  String apiaryLoadError(String error) {
    return 'Não foi possível carregar o apiário: $error';
  }

  @override
  String get apiariesSearchHint => 'Pesquisar apiários por nome';

  @override
  String get apiariesSearchNoResults =>
      'Nenhum apiário corresponde à pesquisa.';

  @override
  String get apiariesLocationServicesDisabled =>
      'Os serviços de localização estão desativados — a mostrar apiários por nome.';

  @override
  String get apiariesLocationPermissionDenied =>
      'Acesso à localização negado — a mostrar apiários por nome.';

  @override
  String get apiariesLocationUnavailable =>
      'Localização indisponível — a mostrar apiários por nome.';

  @override
  String get apiariesLocationRetry => 'Tentar novamente';

  @override
  String get apiariesViewToggleLabel => 'Vista dos apiários';

  @override
  String get apiariesViewListAction => 'Vista de lista';

  @override
  String get apiariesViewMapAction => 'Vista de mapa';

  @override
  String get syncStatusSyncing => 'A sincronizar…';

  @override
  String get syncStatusWaitingForSignal => 'A aguardar melhor sinal';

  @override
  String get syncStatusError => 'Erro de sincronização';

  @override
  String get offlineBannerErrorMessage =>
      'Algumas alterações não foram sincronizadas e o PowerSync está a tentar novamente.';

  @override
  String get syncSupersededNotice =>
      'Uma das suas alterações offline foi substituída por uma edição mais recente.';

  @override
  String get syncRejectedNotice =>
      'Uma das suas alterações foi rejeitada e precisa de correção.';

  @override
  String get syncNeedsFixTitle => 'Alterações a corrigir';

  @override
  String get syncNeedsFixEmpty => 'Não há alterações a corrigir.';

  @override
  String syncNeedsFixLoadError(String error) {
    return 'Não foi possível carregar as alterações a corrigir: $error';
  }

  @override
  String syncNeedsFixCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alterações a corrigir',
      one: '1 alteração a corrigir',
    );
    return '$_temp0';
  }

  @override
  String get syncNeedsFixApiaryLabel => 'Alteração de apiário';

  @override
  String get syncNeedsFixCounterLabel => 'Alteração de nº de colmeias';

  @override
  String get syncNeedsFixGenericProblem =>
      'Esta alteração foi rejeitada e precisa da sua atenção.';

  @override
  String get syncNeedsFixFixAction => 'Corrigir';

  @override
  String get syncNeedsFixDismissAction => 'Dispensar';

  @override
  String get accountSyncSectionTitle => 'Sincronização';

  @override
  String accountSyncStatusLabel(String status) {
    return 'Estado: $status';
  }

  @override
  String accountSyncPendingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alterações por sincronizar.',
      one: '1 alteração por sincronizar.',
      zero: 'Tudo sincronizado.',
    );
    return '$_temp0';
  }

  @override
  String get accountSyncNowButton => 'Sincronizar agora';

  @override
  String get accountSyncNowTriggered => 'Sincronização pedida.';

  @override
  String accountSyncNowError(String error) {
    return 'Não foi possível sincronizar agora: $error';
  }

  @override
  String get apiaryDetailTitle => 'Apiário';

  @override
  String apiaryLocationValue(String lat, String lon) {
    return '$lat, $lon';
  }

  @override
  String get apiaryLocationNotSet => 'Sem localização definida';

  @override
  String get apiaryNotesLabel => 'Notas';

  @override
  String get apiaryNotesHint => 'Flora, acessos, observações…';

  @override
  String get editApiaryAction => 'Editar apiário';

  @override
  String get apiaryMapEmpty => 'Ainda não há apiários com localização.';

  @override
  String get apiaryMapUserLocationLabel => 'Você';

  @override
  String get apiaryMapLocationPermissionDenied =>
      'Localização indisponível — ative o acesso à localização para ver a sua posição no mapa.';

  @override
  String get apiaryMapMeasureHintSelectFirst =>
      'Toque em dois apiários para medir a distância entre eles.';

  @override
  String apiaryMapMeasureHintSelectSecond(String name) {
    return 'Selecionado $name. Toque noutro apiário para medir.';
  }

  @override
  String apiaryMapMeasureResult(String from, String to, String distanceKm) {
    return '$from a $to: $distanceKm km';
  }

  @override
  String get apiaryMapMeasureClear => 'Limpar seleção';

  @override
  String get apiaryMapLayerToggleLabel => 'Camada do mapa';

  @override
  String get apiaryMapLayerSatelliteAction => 'Satélite';

  @override
  String get apiaryMapLayerStreetsAction => 'Ruas';

  @override
  String get apiaryMapAttributionEsri =>
      'Powered by Esri — Fonte: Esri, Maxar, Earthstar Geographics e a comunidade de utilizadores GIS';

  @override
  String get apiaryMapAttributionOsm => '© Colaboradores do OpenStreetMap';

  @override
  String get apiaryPlaceLabelLabel => 'Nome do local';

  @override
  String get apiaryPlaceLabelHint => 'ex.: Montargil';

  @override
  String get apiaryLocationSectionLabel => 'Localização';

  @override
  String get apiaryUseCurrentLocationAction => 'Usar localização atual';

  @override
  String get apiarySetOnMapAction => 'Definir no mapa';

  @override
  String get apiaryHideMapAction => 'Ocultar mapa';

  @override
  String get apiaryLocationClearAction => 'Limpar localização';

  @override
  String get apiaryFormLocationPermissionDenied =>
      'Acesso à localização negado — ainda pode colocar um alfinete no mapa.';

  @override
  String apiaryFormLocationSet(String lat, String lon) {
    return 'Localização definida: $lat, $lon';
  }

  @override
  String get apiaryFormLocationNotSet =>
      'Sem localização definida — toque no mapa para colocar um alfinete';

  @override
  String get apiaryMapPickerLabel =>
      'Mapa: toque para colocar o alfinete do apiário';

  @override
  String apiaryDistanceValue(String distanceKm) {
    return 'a $distanceKm km';
  }

  @override
  String get deleteApiaryConfirmTitle => 'Eliminar apiário?';

  @override
  String deleteApiaryConfirmMessage(String name) {
    return 'Isto elimina permanentemente “$name”. Esta ação não pode ser desfeita.';
  }

  @override
  String get deleteApiaryConfirmAction => 'Eliminar';

  @override
  String get deleteApiaryCancelAction => 'Cancelar';
}
