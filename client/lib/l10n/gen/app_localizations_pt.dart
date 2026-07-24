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
  String get loginPrompt =>
      'Inicie sessão para gerir os seus apiários. É a primeira vez? Toque em Iniciar sessão — pode criar a sua conta no ecrã seguinte.';

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
  String get actionsMenuLabel => 'Ações';

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
  String superCountValue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alças',
      one: '1 alça',
      zero: 'Sem alças',
    );
    return '$_temp0';
  }

  @override
  String get counterTypeHiveLabel => 'Colmeias';

  @override
  String get counterTypeSuperLabel => 'Alças';

  @override
  String emptyHiveCountValue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count colmeias vazias',
      one: '1 colmeia vazia',
      zero: 'Sem colmeias vazias',
    );
    return '$_temp0';
  }

  @override
  String swarmCountValue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count enxames',
      one: '1 enxame',
      zero: 'Sem enxames',
    );
    return '$_temp0';
  }

  @override
  String get counterTypeEmptyHiveLabel => 'Colmeias vazias';

  @override
  String get counterTypeSwarmLabel => 'Enxames';

  @override
  String get apiaryAddCounterAction => 'Adicionar contador';

  @override
  String get apiaryAddCounterTitle => 'Adicionar um contador';

  @override
  String get apiaryNoCountersToAdd =>
      'Já existem contadores de todos os tipos.';

  @override
  String get counterDecrementLabel => 'Diminuir';

  @override
  String get counterIncrementLabel => 'Aumentar';

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
  String get syncNeedsFixActivityLabel => 'Alteração de atividade';

  @override
  String get syncNeedsFixJourneyLabel => 'Alteração de jornada';

  @override
  String get syncNeedsFixJourneyPlanLabel => 'Alteração do plano da jornada';

  @override
  String get syncNeedsFixTodoLabel => 'Alteração de tarefa';

  @override
  String syncNeedsFixTitleWithName(String label, String name) {
    return '$label · $name';
  }

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
  String accountSyncNeedsFixStatus(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alterações foram rejeitadas e precisam de correção.',
      one: '1 alteração foi rejeitada e precisa de correção.',
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
  String get activityDetailTitle => 'Atividade';

  @override
  String get activityDetailAttributesHeader => 'Detalhes';

  @override
  String get activityPerformedByLabel => 'Realizada por';

  @override
  String get editActivityAction => 'Editar atividade';

  @override
  String get editActivityTitle => 'Editar atividade';

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
  String get apiaryMapRulerToggleAction => 'Medir distância';

  @override
  String get apiaryMapMeasureFromMyLocation => 'Usar a minha localização';

  @override
  String apiaryMapInfoOpenTodos(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tarefas em aberto',
      one: '1 tarefa em aberto',
      zero: 'Nenhuma tarefa em aberto',
    );
    return '$_temp0';
  }

  @override
  String get apiaryMapInfoViewApiary => 'Ver apiário';

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
  String get apiaryLocationRequired =>
      'Defina a localização do apiário antes de guardar.';

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

  @override
  String get activityTypeHarvestLabel => 'Cresta';

  @override
  String get activityTypeFeedingLabel => 'Alimentação';

  @override
  String get activityTypeTreatmentLabel => 'Tratamento';

  @override
  String get activityTypeGenericLabel => 'Genérica';

  @override
  String get treatmentContextGeneralLabel => 'Geral / preventivo';

  @override
  String get treatmentContextDiseaseSpecificLabel =>
      'Doença/condição específica';

  @override
  String get treatmentContextDetectionOnlyLabel =>
      'Deteção apenas (sem tratamento ainda)';

  @override
  String get newActivityTitle => 'Adicionar atividade';

  @override
  String get addActivityAction => 'Adicionar atividade';

  @override
  String get activityTypeFieldLabel => 'Tipo de atividade';

  @override
  String get activityOccurredAtLabel => 'Data';

  @override
  String get activityHoneySupersLabel => 'Alças de mel colhidas';

  @override
  String get activityHoneyKgLabel => 'Mel colhido (kg)';

  @override
  String get activityHivesInvolvedLabel => 'Colmeias envolvidas';

  @override
  String get activityFeedTypeLabel => 'Tipo de alimento';

  @override
  String get activityFeedAmountLabel => 'Quantidade de alimento';

  @override
  String get activityTreatmentContextFieldLabel => 'Contexto do tratamento';

  @override
  String get activityTreatmentTypeLabel => 'Produto de tratamento';

  @override
  String get activityDiseaseLabel => 'Doença / condição';

  @override
  String get activityTreatmentTypeOptionalForDetectionHint =>
      'Opcional para um registo de deteção apenas';

  @override
  String get activityLotBatchLabel => 'Identificador de lote';

  @override
  String get activityNotesLabel => 'Notas';

  @override
  String get activityFieldRequired => 'Este campo é obrigatório';

  @override
  String get activityFieldInvalid => 'Este valor não é válido';

  @override
  String get activitySaveSuccess => 'Atividade guardada';

  @override
  String activitySaveError(String error) {
    return 'Não foi possível guardar a atividade: $error';
  }

  @override
  String get apiaryActivitiesEmpty =>
      'Ainda não há atividades registadas para este apiário.';

  @override
  String apiaryActivitiesViewAll(int count) {
    return 'Ver todas as $count atividades';
  }

  @override
  String get activitiesEmpty => 'Ainda não há atividades.';

  @override
  String get activitiesFilterNoResults =>
      'Nenhuma atividade corresponde aos filtros.';

  @override
  String activitiesError(String error) {
    return 'Não foi possível carregar as atividades: $error';
  }

  @override
  String get activityFilterTypeLabel => 'Tipo';

  @override
  String get activityFilterTypeAll => 'Todos os tipos';

  @override
  String get activityFilterDateRangeLabel => 'Intervalo de datas';

  @override
  String get activityFilterDateRangeUnset => 'Qualquer data';

  @override
  String activityFilterDateRangeValue(String start, String end) {
    return '$start – $end';
  }

  @override
  String get activityFilterClearAction => 'Limpar filtros';

  @override
  String get activityPerformedByYou => 'Você';

  @override
  String activityPerformedByMember(String id) {
    return 'Membro $id';
  }

  @override
  String get activityPerformedByUnknown => 'Desconhecido';

  @override
  String activityPerformedBySemanticLabel(String who) {
    return 'Realizada por: $who';
  }

  @override
  String get activityNoAttributesSummary => 'Sem detalhes adicionais';

  @override
  String activityLoadError(String error) {
    return 'Não foi possível carregar a atividade: $error';
  }

  @override
  String get deleteActivity => 'Eliminar atividade';

  @override
  String get activityDeleteSuccess => 'Atividade eliminada';

  @override
  String activityDeleteError(String error) {
    return 'Não foi possível eliminar a atividade: $error';
  }

  @override
  String get deleteActivityConfirmTitle => 'Eliminar atividade?';

  @override
  String get deleteActivityConfirmMessage =>
      'Isto elimina permanentemente esta atividade. Esta ação não pode ser desfeita.';

  @override
  String get deleteActivityConfirmAction => 'Eliminar';

  @override
  String get deleteActivityCancelAction => 'Cancelar';

  @override
  String get addJourney => 'Nova jornada';

  @override
  String get newJourneyTitle => 'Nova jornada';

  @override
  String get editJourneyTitle => 'Editar jornada';

  @override
  String get journeysEmpty =>
      'Ainda não há jornadas. Toque em “Nova jornada” para criar uma.';

  @override
  String journeysError(String error) {
    return 'Não foi possível carregar as jornadas: $error';
  }

  @override
  String get journeysFilterNoResults =>
      'Nenhuma jornada corresponde aos filtros.';

  @override
  String get journeyFilterTypeLabel => 'Tipo';

  @override
  String get journeyFilterTypeAll => 'Todos os tipos';

  @override
  String get journeyFilterDateRangeLabel => 'Intervalo de datas';

  @override
  String get journeyFilterDateRangeUnset => 'Qualquer data';

  @override
  String journeyFilterDateRangeValue(String start, String end) {
    return '$start – $end';
  }

  @override
  String get journeyFilterClearAction => 'Limpar filtros';

  @override
  String journeyProgressBadge(int done, int planned) {
    return '$done/$planned apiários visitados';
  }

  @override
  String get journeyNameLabel => 'Nome';

  @override
  String get journeyNameRequired => 'O nome é obrigatório';

  @override
  String get journeyMainActivityTypeLabel => 'Atividade principal';

  @override
  String get journeyApiariesLabel => 'Apiários a visitar';

  @override
  String get journeyApiariesRequired => 'Selecione pelo menos um apiário';

  @override
  String get journeyApiariesNoneAvailable =>
      'Ainda não há apiários — adicione um no separador Apiários primeiro.';

  @override
  String get journeyApiariesSelectAll => 'Selecionar todos';

  @override
  String get journeyApiariesClearAll => 'Limpar tudo';

  @override
  String journeyApiariesSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count apiários selecionados',
      one: '1 apiário selecionado',
      zero: 'Nenhum apiário selecionado',
    );
    return '$_temp0';
  }

  @override
  String get journeyDefaultAttributesSectionLabel =>
      'Predefinições para atividades';

  @override
  String get journeyDefaultsNotSetOption => 'Não definido';

  @override
  String journeyLoadError(String error) {
    return 'Não foi possível carregar a jornada: $error';
  }

  @override
  String get journeySaveSuccess => 'Jornada guardada';

  @override
  String journeySaveError(String error) {
    return 'Não foi possível guardar a jornada: $error';
  }

  @override
  String get closeJourneyAction => 'Fechar jornada';

  @override
  String get journeyCloseSuccess => 'Jornada fechada';

  @override
  String journeyCloseError(String error) {
    return 'Não foi possível fechar a jornada: $error';
  }

  @override
  String get journeyStatusOpenLabel => 'Aberta';

  @override
  String get journeyStatusClosedLabel => 'Fechada';

  @override
  String journeyStatusSemanticLabel(String label) {
    return 'Estado: $label';
  }

  @override
  String get deleteJourney => 'Eliminar jornada';

  @override
  String get journeyDeleteSuccess => 'Jornada eliminada';

  @override
  String journeyDeleteError(String error) {
    return 'Não foi possível eliminar a jornada: $error';
  }

  @override
  String get deleteJourneyConfirmTitle => 'Eliminar jornada?';

  @override
  String get deleteJourneyConfirmMessage =>
      'Isto elimina permanentemente esta jornada. Esta ação não pode ser desfeita.';

  @override
  String get deleteJourneyConfirmAction => 'Eliminar';

  @override
  String get deleteJourneyCancelAction => 'Cancelar';

  @override
  String get journeyAttachmentLabel => 'Jornada';

  @override
  String get journeyAttachmentNone => 'Nenhuma jornada associada';

  @override
  String get journeyAttachmentAutoSelectedHint =>
      'Selecionada automaticamente — corresponde a este apiário e tipo de atividade';

  @override
  String get journeyAttachmentChangeAction => 'Alterar';

  @override
  String get journeyAttachmentRemoveAction => 'Remover';

  @override
  String get journeyPickerTitle => 'Escolher uma jornada';

  @override
  String journeyPickerError(String error) {
    return 'Não foi possível carregar as jornadas: $error';
  }

  @override
  String get journeyPickerNoneOption => 'Nenhuma jornada';

  @override
  String get journeyPickerNoOpenMatches =>
      'Ainda não há jornadas abertas correspondentes a este apiário e tipo de atividade.';

  @override
  String get journeyPickerShowHiddenToggle => 'Mostrar jornadas ocultas';

  @override
  String journeyPickerClosedOptionSemanticLabel(String name) {
    return '$name, jornada fechada';
  }

  @override
  String get journeyPickerCreateNewAction => 'Criar nova jornada';

  @override
  String get journeyQuickCreateTitle => 'Nova jornada';

  @override
  String get journeyQuickCreateCancelAction => 'Cancelar';

  @override
  String get closedJourneyConfirmTitle => 'Esta jornada está fechada';

  @override
  String closedJourneyConfirmMessage(String journeyName) {
    return '\"$journeyName\" está fechada. Adicionar esta atividade mesmo assim?';
  }

  @override
  String get closedJourneyConfirmCancelAction => 'Cancelar';

  @override
  String get closedJourneyConfirmAddAction => 'Adicionar mesmo assim';

  @override
  String get journeyRelinkConfirmTitle => 'Alterar a jornada associada?';

  @override
  String journeyRelinkConfirmMessage(
    String oldJourneyName,
    String newJourneyName,
  ) {
    return 'Esta atividade vai passar de \"$oldJourneyName\" para \"$newJourneyName\".';
  }

  @override
  String get journeyRelinkConfirmCancelAction => 'Cancelar';

  @override
  String get journeyRelinkConfirmConfirmAction => 'Confirmar';

  @override
  String get journeyStatsSectionTitle => 'Estatísticas da jornada';

  @override
  String journeyStatsError(String error) {
    return 'Não foi possível carregar as estatísticas da jornada: $error';
  }

  @override
  String get journeyStatsApiariesVisitedLabel => 'Apiários visitados';

  @override
  String journeyStatsApiariesVisitedValue(int done, int planned) {
    return '$done/$planned';
  }

  @override
  String get journeyStatsHivesHarvestedLabel => 'Colmeias trabalhadas';

  @override
  String get journeyStatsHoneyCollectedLabel => 'Mel colhido';

  @override
  String journeyStatsHoneyCollectedValue(String kg) {
    return '$kg kg';
  }

  @override
  String get journeyStatsAverageSupersLabel => 'Média alças/colmeia';

  @override
  String get journeyStatsAverageSupersNoData => 'Ainda sem dados';

  @override
  String journeyStatsMissingLabel(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Faltam $count apiários',
      one: 'Falta 1 apiário',
      zero: 'Todos os apiários planeados foram visitados',
    );
    return '$_temp0';
  }

  @override
  String get journeyStatsHivesWorkedLabel => 'Colmeias trabalhadas (total)';

  @override
  String journeyStatsHivesWorkedValue(int worked, String planned) {
    return '$worked/$planned';
  }

  @override
  String get journeyStatsHivesWorkedNoData => '—';

  @override
  String get journeyStatsMoreAction => 'Mais estatísticas';

  @override
  String get journeyStatsDetailTitle => 'Mais estatísticas';

  @override
  String get journeyStatsDetailFilterAll => 'Todos';

  @override
  String get journeyStatsDetailFilterVisited => 'Visitados';

  @override
  String get journeyStatsDetailFilterNotVisited => 'Não visitados';

  @override
  String get journeyStatsDetailSortLabel => 'Ordenar por';

  @override
  String get journeyStatsDetailSortName => 'Nome';

  @override
  String get journeyStatsDetailSortKgPerHive => 'Kg/colmeia';

  @override
  String get journeyStatsDetailSortSupersPerHive => 'Alças/colmeia';

  @override
  String get journeyStatsDetailSortFeedAmount => 'Quantidade de alimento';

  @override
  String get journeyStatsDetailSortHivesInvolved => 'Colmeias envolvidas';

  @override
  String get journeyStatsDetailEmpty =>
      'Nenhum apiário corresponde ao filtro atual.';

  @override
  String get journeyStatsDetailHiveCountLabel => 'Colmeias';

  @override
  String get journeyStatsDetailHoneyKgLabel => 'Mel (kg)';

  @override
  String get journeyStatsDetailSupersLabel => 'Alças';

  @override
  String get journeyStatsDetailKgPerHiveLabel => 'Kg/colmeia';

  @override
  String get journeyStatsDetailSupersPerHiveLabel => 'Alças/colmeia';

  @override
  String get journeyStatsDetailFeedAmountLabel => 'Quantidade de alimento';

  @override
  String get journeyStatsDetailHivesInvolvedLabel => 'Colmeias envolvidas';

  @override
  String get journeyStatsDetailNoDataValue => '—';

  @override
  String journeyStatsDetailFeedingSummary(String amount) {
    return 'Quantidade total de alimento: $amount';
  }

  @override
  String journeyStatsDetailTreatedSummary(int treated, int planned) {
    return '$treated/$planned apiários tratados';
  }

  @override
  String get journeyDetailTitle => 'Jornada';

  @override
  String get editJourneyAction => 'Editar jornada';

  @override
  String journeyDetailDefaultAttributesLabel(String values) {
    return 'Predefinições: $values';
  }

  @override
  String get journeyDetailApiariesTitle => 'Apiários';

  @override
  String get journeyDetailApiaryNameUnknown => 'Apiário desconhecido';

  @override
  String get journeyDetailApiaryVisitedBadge => 'Visitado';

  @override
  String get journeyDetailApiaryPlannedBadge => 'Planeado';

  @override
  String get journeyDetailApiaryNotVisitedYet => 'Ainda não visitado';

  @override
  String get journeyDetailApiariesEmpty =>
      'Ainda não há apiários nesta jornada.';

  @override
  String get todosEmpty => 'Ainda não há tarefas.';

  @override
  String get todosFilterNoResults => 'Nenhuma tarefa corresponde aos filtros.';

  @override
  String todosError(String error) {
    return 'Não foi possível carregar as tarefas: $error';
  }

  @override
  String get todoFilterStatusLabel => 'Estado';

  @override
  String get todoFilterStatusAll => 'Todas';

  @override
  String get todoFilterStatusOpen => 'Em aberto';

  @override
  String get todoFilterStatusOverdue => 'Atrasada';

  @override
  String get todoFilterStatusDone => 'Concluída';

  @override
  String get todoFilterPriorityLabel => 'Prioridade';

  @override
  String get todoFilterPriorityAll => 'Todas as prioridades';

  @override
  String get todoPriorityLowLabel => 'Baixa';

  @override
  String get todoPriorityMediumLabel => 'Média';

  @override
  String get todoPriorityHighLabel => 'Alta';

  @override
  String get todoFilterDueLabel => 'Prazo';

  @override
  String get todoFilterDueAny => 'Qualquer data';

  @override
  String get todoFilterDueToday => 'Vence hoje';

  @override
  String get todoFilterDueThisWeek => 'Vence esta semana';

  @override
  String get todoFilterDueThisMonth => 'Vence este mês';

  @override
  String get todoFilterClearAction => 'Limpar filtros';

  @override
  String get todoSortFieldLabel => 'Ordenar por';

  @override
  String get todoSortFieldDueDate => 'Prazo';

  @override
  String get todoSortFieldPriority => 'Prioridade';

  @override
  String get todoSortFieldStatus => 'Estado';

  @override
  String get todoSortDirectionAscendingLabel => 'Crescente';

  @override
  String get todoSortDirectionDescendingLabel => 'Decrescente';

  @override
  String get todoDueDateUnset => 'Sem prazo';

  @override
  String get todoOverdueBadge => 'Atrasada';

  @override
  String todoStatusSemanticLabel(String status) {
    return 'Estado: $status';
  }

  @override
  String get addTodo => 'Nova tarefa';

  @override
  String get newTodoTitle => 'Nova tarefa';

  @override
  String get todoDetailTitle => 'Tarefa';

  @override
  String get editTodoTitle => 'Editar tarefa';

  @override
  String get editTodoAction => 'Editar tarefa';

  @override
  String get todoTitleLabel => 'Título';

  @override
  String get todoTitleRequired => 'O título é obrigatório';

  @override
  String get todoDescriptionLabel => 'Descrição';

  @override
  String get todoDescriptionUnset => 'Sem descrição';

  @override
  String get todoDueDateFieldLabel => 'Prazo';

  @override
  String get todoDueDateClearAction => 'Limpar prazo';

  @override
  String get todoPriorityFieldLabel => 'Prioridade';

  @override
  String get todoAssigneeFieldLabel => 'Responsável';

  @override
  String get todoApiaryFieldLabel => 'Apiário';

  @override
  String get todoAssigneeUnassigned => 'Sem responsável';

  @override
  String todoAssigneeUnknown(String id) {
    return 'Membro $id';
  }

  @override
  String get todoAssigneeNoneAvailable => 'Ainda não há membros disponíveis.';

  @override
  String get todoApiaryNone => 'Sem apiário';

  @override
  String get todoApiaryUnknown => 'Apiário desconhecido';

  @override
  String get todoDetailFieldsHeader => 'Detalhes';

  @override
  String get todoCompletedAtLabel => 'Concluída em';

  @override
  String get todoCompleteAction => 'Marcar como concluída';

  @override
  String get todoReopenAction => 'Reabrir';

  @override
  String get todoCompleteSuccess => 'Tarefa concluída';

  @override
  String todoCompleteError(String error) {
    return 'Não foi possível atualizar a tarefa: $error';
  }

  @override
  String get todoReopenSuccess => 'Tarefa reaberta';

  @override
  String todoReopenError(String error) {
    return 'Não foi possível atualizar a tarefa: $error';
  }

  @override
  String get todoSaveSuccess => 'Tarefa guardada';

  @override
  String todoSaveError(String error) {
    return 'Não foi possível guardar a tarefa: $error';
  }

  @override
  String todoLoadError(String error) {
    return 'Não foi possível carregar a tarefa: $error';
  }

  @override
  String get deleteTodo => 'Eliminar tarefa';

  @override
  String get todoDeleteSuccess => 'Tarefa eliminada';

  @override
  String todoDeleteError(String error) {
    return 'Não foi possível eliminar a tarefa: $error';
  }

  @override
  String get deleteTodoConfirmTitle => 'Eliminar tarefa?';

  @override
  String get deleteTodoConfirmMessage =>
      'Isto elimina permanentemente esta tarefa. Esta ação não pode ser desfeita.';

  @override
  String get deleteTodoConfirmAction => 'Eliminar';

  @override
  String get deleteTodoCancelAction => 'Cancelar';

  @override
  String get historySectionTitle => 'Histórico';

  @override
  String get historyScreenTitle => 'Histórico';

  @override
  String get historyEmpty => 'Ainda não há alterações registadas';

  @override
  String historyError(String error) {
    return 'Não foi possível carregar o histórico: $error';
  }

  @override
  String get historyViewAllAction => 'Ver tudo';

  @override
  String get historyEventCreated => 'Criado';

  @override
  String get historyEventUpdated => 'Atualizado';

  @override
  String get historyEventDeleted => 'Eliminado';

  @override
  String get historyEventSuperseded => 'Substituído';

  @override
  String get historyEventUnknown => 'Alterado';

  @override
  String historyChangedFieldsValue(String fields) {
    return 'Alterado: $fields';
  }

  @override
  String get historySupersededDetail =>
      'Substituído por uma versão mais recente de outro dispositivo';

  @override
  String get historyActorYou => 'Você';

  @override
  String historyActorMember(String id) {
    return 'Membro $id';
  }

  @override
  String get historyActorUnknown => 'Desconhecido';

  @override
  String historyEntrySemanticLabel(
    String event,
    String actor,
    String timestamp,
  ) {
    return '$event por $actor, $timestamp';
  }

  @override
  String get historyFieldLocation => 'Localização';

  @override
  String get historyFieldActivityType => 'Tipo de atividade';

  @override
  String get historyFieldAttributes => 'Detalhes';

  @override
  String get historyFieldApiary => 'Apiário';

  @override
  String get discardChangesTitle => 'Descartar alterações?';

  @override
  String get discardChangesMessage =>
      'Tem alterações por guardar. Se sair agora, serão perdidas.';

  @override
  String get discardChangesConfirmAction => 'Descartar';

  @override
  String get discardChangesCancelAction => 'Continuar a editar';
}
