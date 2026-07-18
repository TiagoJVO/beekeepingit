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
  String get loginButton => 'Sign in';

  @override
  String get loginError =>
      'Couldn\'t sign in — check your connection and try again.';

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

  @override
  String get profileGenericError => 'Something went wrong. Please try again.';

  @override
  String get organizationTitle => 'Your organization';

  @override
  String get organizationOnboardingIntro =>
      'Create your organization to start managing apiaries.';

  @override
  String get organizationNameLabel => 'Organization name';

  @override
  String get organizationNameRequired => 'Enter an organization name.';

  @override
  String get organizationAddressLabel => 'Address (optional)';

  @override
  String get organizationSaveButton => 'Create organization';

  @override
  String get organizationSaveSuccess => 'Organization created.';

  @override
  String organizationSaveError(String error) {
    return 'Could not create your organization: $error';
  }

  @override
  String get membersTitle => 'Members & invitations';

  @override
  String membersLoadError(String error) {
    return 'Could not load members: $error';
  }

  @override
  String get membersInviteEmailLabel => 'Email to invite';

  @override
  String get membersInviteEmailRequired => 'Enter an email address.';

  @override
  String get membersInviteEmailInvalid => 'Enter a valid email address.';

  @override
  String get membersInviteButton => 'Invite';

  @override
  String get membersInviteSuccess => 'Invitation sent.';

  @override
  String membersInviteError(String error) {
    return 'Could not complete the request: $error';
  }

  @override
  String get membersSectionTitle => 'Members';

  @override
  String get membersEmpty => 'No members yet.';

  @override
  String get invitationsSectionTitle => 'Invitations';

  @override
  String get invitationsEmpty => 'No invitations yet.';

  @override
  String get membersRevokeButton => 'Revoke invitation';

  @override
  String get membersRevokeSuccess => 'Invitation revoked.';

  @override
  String get memberRoleAdmin => 'Admin';

  @override
  String get memberRoleUser => 'Member';

  @override
  String get memberStatusActive => 'Active';

  @override
  String get memberStatusInvited => 'Invited';

  @override
  String get memberStatusRemoved => 'Removed';

  @override
  String get invitationStatusPending => 'Pending';

  @override
  String get invitationStatusAccepted => 'Accepted';

  @override
  String get invitationStatusExpired => 'Expired';

  @override
  String get invitationStatusRevoked => 'Revoked';

  @override
  String get membersLoadMoreButton => 'Load more';

  @override
  String get manageMembers => 'Manage members';

  @override
  String get accountTitle => 'Account settings';

  @override
  String get accountProfileSectionTitle => 'Profile';

  @override
  String get accountSecuritySectionTitle => 'Security';

  @override
  String get accountChangePasswordHint =>
      'Password changes are handled by our sign-in provider, in a new tab.';

  @override
  String get accountChangePasswordButton => 'Change password';

  @override
  String get accountOrganizationSectionTitle => 'Organization';

  @override
  String get activitiesTitle => 'Activities';

  @override
  String get journeysTitle => 'Journeys';

  @override
  String get todosTitle => 'Todos';

  @override
  String get assistantTitle => 'Assistant';

  @override
  String get activitiesComingSoon => 'Activities — coming soon';

  @override
  String get journeysComingSoon => 'Journeys — coming soon';

  @override
  String get todosComingSoon => 'Todos — coming soon';

  @override
  String get assistantComingSoon => 'Assistant — coming soon';

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
    return 'Sync status: $label. Opens sync settings.';
  }

  @override
  String offlineBannerMessage(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'No connection — changes are saved locally ($count to sync)',
      one: 'No connection — changes are saved locally (1 to sync)',
      zero: 'No connection — changes are saved locally',
    );
    return '$_temp0';
  }

  @override
  String get apiarySaveSuccess => 'Apiary saved.';

  @override
  String get apiaryDeleteSuccess => 'Apiary deleted.';

  @override
  String apiarySaveError(String error) {
    return 'Could not save the apiary: $error';
  }

  @override
  String apiaryDeleteError(String error) {
    return 'Could not delete the apiary: $error';
  }

  @override
  String apiaryLoadError(String error) {
    return 'Could not load the apiary: $error';
  }

  @override
  String get apiariesSearchHint => 'Search apiaries by name';

  @override
  String get apiariesSearchNoResults => 'No apiaries match your search.';

  @override
  String get apiariesLocationServicesDisabled =>
      'Location services are off — showing apiaries by name.';

  @override
  String get apiariesLocationPermissionDenied =>
      'Location access denied — showing apiaries by name.';

  @override
  String get apiariesLocationUnavailable =>
      'Location unavailable — showing apiaries by name.';

  @override
  String get apiariesLocationRetry => 'Retry';

  @override
  String get apiariesViewToggleLabel => 'Apiaries view';

  @override
  String get apiariesViewListAction => 'List view';

  @override
  String get apiariesViewMapAction => 'Map view';

  @override
  String get syncStatusSyncing => 'Syncing…';

  @override
  String get syncStatusWaitingForSignal => 'Waiting for better signal';

  @override
  String get syncStatusError => 'Sync error';

  @override
  String get offlineBannerErrorMessage =>
      'Some changes failed to sync and PowerSync is retrying.';

  @override
  String get syncSupersededNotice =>
      'One of your offline changes was overwritten by a newer edit.';

  @override
  String get syncRejectedNotice =>
      'One of your changes was rejected and needs fixing.';

  @override
  String get syncNeedsFixTitle => 'Changes to fix';

  @override
  String get syncNeedsFixEmpty => 'No changes need fixing.';

  @override
  String syncNeedsFixLoadError(String error) {
    return 'Couldn\'t load the changes to fix: $error';
  }

  @override
  String syncNeedsFixCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes need fixing',
      one: '1 change needs fixing',
    );
    return '$_temp0';
  }

  @override
  String get syncNeedsFixApiaryLabel => 'Apiary change';

  @override
  String get syncNeedsFixCounterLabel => 'Hive count change';

  @override
  String get syncNeedsFixGenericProblem =>
      'This change was rejected and needs your attention.';

  @override
  String get syncNeedsFixFixAction => 'Fix';

  @override
  String get syncNeedsFixDismissAction => 'Dismiss';

  @override
  String get accountSyncSectionTitle => 'Sync';

  @override
  String accountSyncStatusLabel(String status) {
    return 'Status: $status';
  }

  @override
  String accountSyncPendingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes waiting to sync.',
      one: '1 change waiting to sync.',
      zero: 'Everything is synced.',
    );
    return '$_temp0';
  }

  @override
  String get accountSyncNowButton => 'Sync now';

  @override
  String get accountSyncNowTriggered => 'Sync requested.';

  @override
  String accountSyncNowError(String error) {
    return 'Could not sync right now: $error';
  }

  @override
  String get apiaryDetailTitle => 'Apiary';

  @override
  String get activityDetailTitle => 'Activity';

  @override
  String get activityDetailAttributesHeader => 'Details';

  @override
  String get activityPerformedByLabel => 'Performed by';

  @override
  String get editActivityAction => 'Edit activity';

  @override
  String get editActivityTitle => 'Edit activity';

  @override
  String apiaryLocationValue(String lat, String lon) {
    return '$lat, $lon';
  }

  @override
  String get apiaryLocationNotSet => 'No location set';

  @override
  String get apiaryNotesLabel => 'Notes';

  @override
  String get apiaryNotesHint => 'Flora, access, observations…';

  @override
  String get editApiaryAction => 'Edit apiary';

  @override
  String get apiaryMapEmpty => 'No apiaries with a location yet.';

  @override
  String get apiaryMapUserLocationLabel => 'You';

  @override
  String get apiaryMapLocationPermissionDenied =>
      'Location unavailable — enable location access to see your position on the map.';

  @override
  String get apiaryMapMeasureHintSelectFirst =>
      'Tap two apiaries to measure the distance between them.';

  @override
  String apiaryMapMeasureHintSelectSecond(String name) {
    return 'Selected $name. Tap another apiary to measure.';
  }

  @override
  String apiaryMapMeasureResult(String from, String to, String distanceKm) {
    return '$from to $to: $distanceKm km';
  }

  @override
  String get apiaryMapMeasureClear => 'Clear selection';

  @override
  String get apiaryMapLayerToggleLabel => 'Map layer';

  @override
  String get apiaryMapLayerSatelliteAction => 'Satellite';

  @override
  String get apiaryMapLayerStreetsAction => 'Streets';

  @override
  String get apiaryMapAttributionEsri =>
      'Powered by Esri — Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community';

  @override
  String get apiaryMapAttributionOsm => '© OpenStreetMap contributors';

  @override
  String get apiaryPlaceLabelLabel => 'Place label';

  @override
  String get apiaryPlaceLabelHint => 'e.g. Montargil';

  @override
  String get apiaryLocationSectionLabel => 'Location';

  @override
  String get apiaryUseCurrentLocationAction => 'Use current location';

  @override
  String get apiarySetOnMapAction => 'Set on map';

  @override
  String get apiaryHideMapAction => 'Hide map';

  @override
  String get apiaryLocationClearAction => 'Clear location';

  @override
  String get apiaryFormLocationPermissionDenied =>
      'Location access denied — you can still place a pin on the map.';

  @override
  String apiaryFormLocationSet(String lat, String lon) {
    return 'Location set: $lat, $lon';
  }

  @override
  String get apiaryFormLocationNotSet =>
      'No location set — tap the map to place a pin';

  @override
  String get apiaryMapPickerLabel => 'Map: tap to place the apiary\'s pin';

  @override
  String apiaryDistanceValue(String distanceKm) {
    return '$distanceKm km away';
  }

  @override
  String get deleteApiaryConfirmTitle => 'Delete apiary?';

  @override
  String deleteApiaryConfirmMessage(String name) {
    return 'This permanently deletes “$name”. This cannot be undone.';
  }

  @override
  String get deleteApiaryConfirmAction => 'Delete';

  @override
  String get deleteApiaryCancelAction => 'Cancel';

  @override
  String get activityTypeHarvestLabel => 'Honey harvest';

  @override
  String get activityTypeFeedingLabel => 'Feeding';

  @override
  String get activityTypeTreatmentLabel => 'Treatment';

  @override
  String get activityTypeGenericLabel => 'Generic';

  @override
  String get treatmentContextGeneralLabel => 'General / preventive';

  @override
  String get treatmentContextDiseaseSpecificLabel =>
      'Specific disease/condition';

  @override
  String get treatmentContextDetectionOnlyLabel =>
      'Detection only (no treatment yet)';

  @override
  String get newActivityTitle => 'Add activity';

  @override
  String get addActivityAction => 'Add activity';

  @override
  String get activityTypeFieldLabel => 'Activity type';

  @override
  String get activityOccurredAtLabel => 'Date';

  @override
  String get activityHoneySupersLabel => 'Honey supers harvested';

  @override
  String get activityHoneyKgLabel => 'Honey harvested (kg)';

  @override
  String get activityHivesInvolvedLabel => 'Hives involved';

  @override
  String get activityFeedTypeLabel => 'Feed type';

  @override
  String get activityFeedAmountLabel => 'Feed amount';

  @override
  String get activityTreatmentContextFieldLabel => 'Treatment context';

  @override
  String get activityTreatmentTypeLabel => 'Treatment product';

  @override
  String get activityDiseaseLabel => 'Disease / condition';

  @override
  String get activityTreatmentTypeOptionalForDetectionHint =>
      'Optional for a detection-only report';

  @override
  String get activityLotBatchLabel => 'Lot / batch identifier';

  @override
  String get activityNotesLabel => 'Notes';

  @override
  String get activityFieldRequired => 'This field is required';

  @override
  String get activityFieldInvalid => 'This value isn\'t valid';

  @override
  String get activitySaveSuccess => 'Activity saved';

  @override
  String activitySaveError(String error) {
    return 'Couldn\'t save the activity: $error';
  }

  @override
  String get apiaryActivitiesEmpty =>
      'No activities logged for this apiary yet.';

  @override
  String apiaryActivitiesViewAll(int count) {
    return 'View all $count activities';
  }

  @override
  String get activitiesEmpty => 'No activities yet.';

  @override
  String get activitiesFilterNoResults => 'No activities match your filters.';

  @override
  String activitiesError(String error) {
    return 'Could not load activities: $error';
  }

  @override
  String get activityFilterTypeLabel => 'Type';

  @override
  String get activityFilterTypeAll => 'All types';

  @override
  String get activityFilterDateRangeLabel => 'Date range';

  @override
  String get activityFilterDateRangeUnset => 'Any date';

  @override
  String activityFilterDateRangeValue(String start, String end) {
    return '$start – $end';
  }

  @override
  String get activityFilterClearAction => 'Clear filters';

  @override
  String get activityPerformedByYou => 'You';

  @override
  String activityPerformedByMember(String id) {
    return 'Member $id';
  }

  @override
  String get activityPerformedByUnknown => 'Unknown';

  @override
  String activityPerformedBySemanticLabel(String who) {
    return 'Performed by: $who';
  }

  @override
  String get activityNoAttributesSummary => 'No additional details';

  @override
  String activityLoadError(String error) {
    return 'Couldn\'t load the activity: $error';
  }

  @override
  String get deleteActivity => 'Delete activity';

  @override
  String get activityDeleteSuccess => 'Activity deleted';

  @override
  String activityDeleteError(String error) {
    return 'Couldn\'t delete the activity: $error';
  }

  @override
  String get deleteActivityConfirmTitle => 'Delete activity?';

  @override
  String get deleteActivityConfirmMessage =>
      'This permanently deletes this activity. This cannot be undone.';

  @override
  String get deleteActivityConfirmAction => 'Delete';

  @override
  String get deleteActivityCancelAction => 'Cancel';

  @override
  String get addJourney => 'New journey';

  @override
  String get newJourneyTitle => 'New journey';

  @override
  String get editJourneyTitle => 'Edit journey';

  @override
  String get journeysEmpty =>
      'No journeys yet. Tap “New journey” to create one.';

  @override
  String journeysError(String error) {
    return 'Could not load journeys: $error';
  }

  @override
  String get journeysFilterNoResults => 'No journeys match your filters.';

  @override
  String get journeyFilterTypeLabel => 'Type';

  @override
  String get journeyFilterTypeAll => 'All types';

  @override
  String get journeyFilterDateRangeLabel => 'Date range';

  @override
  String get journeyFilterDateRangeUnset => 'Any date';

  @override
  String journeyFilterDateRangeValue(String start, String end) {
    return '$start – $end';
  }

  @override
  String get journeyFilterClearAction => 'Clear filters';

  @override
  String journeyProgressBadge(int done, int planned) {
    return '$done/$planned apiaries visited';
  }

  @override
  String get journeyNameLabel => 'Name';

  @override
  String get journeyNameRequired => 'Name is required';

  @override
  String get journeyMainActivityTypeLabel => 'Main activity type';

  @override
  String get journeyApiariesLabel => 'Apiaries to visit';

  @override
  String get journeyApiariesRequired => 'Select at least one apiary';

  @override
  String get journeyApiariesNoneAvailable =>
      'No apiaries yet — add one from the Apiaries tab first.';

  @override
  String journeyApiariesSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count apiaries selected',
      one: '1 apiary selected',
      zero: 'No apiaries selected',
    );
    return '$_temp0';
  }

  @override
  String journeyLoadError(String error) {
    return 'Couldn\'t load the journey: $error';
  }

  @override
  String get journeySaveSuccess => 'Journey saved';

  @override
  String journeySaveError(String error) {
    return 'Couldn\'t save the journey: $error';
  }

  @override
  String get closeJourneyAction => 'Close journey';

  @override
  String get journeyCloseSuccess => 'Journey closed';

  @override
  String journeyCloseError(String error) {
    return 'Couldn\'t close the journey: $error';
  }

  @override
  String get journeyStatusOpenLabel => 'Open';

  @override
  String get journeyStatusClosedLabel => 'Closed';

  @override
  String journeyStatusSemanticLabel(String label) {
    return 'Status: $label';
  }

  @override
  String get deleteJourney => 'Delete journey';

  @override
  String get journeyDeleteSuccess => 'Journey deleted';

  @override
  String journeyDeleteError(String error) {
    return 'Couldn\'t delete the journey: $error';
  }

  @override
  String get deleteJourneyConfirmTitle => 'Delete journey?';

  @override
  String get deleteJourneyConfirmMessage =>
      'This permanently deletes this journey. This cannot be undone.';

  @override
  String get deleteJourneyConfirmAction => 'Delete';

  @override
  String get deleteJourneyCancelAction => 'Cancel';

  @override
  String get journeyAttachmentLabel => 'Journey';

  @override
  String get journeyAttachmentNone => 'No journey attached';

  @override
  String get journeyAttachmentAutoSelectedHint =>
      'Auto-selected — matches this apiary and activity type';

  @override
  String get journeyAttachmentChangeAction => 'Change';

  @override
  String get journeyAttachmentRemoveAction => 'Remove';

  @override
  String get journeyPickerTitle => 'Choose a journey';

  @override
  String journeyPickerError(String error) {
    return 'Couldn\'t load journeys: $error';
  }

  @override
  String get journeyPickerNoneOption => 'No journey';

  @override
  String get journeyPickerNoOpenMatches =>
      'No open journeys match this apiary and activity type yet.';

  @override
  String get journeyPickerShowHiddenToggle => 'Show hidden journeys';

  @override
  String journeyPickerClosedOptionSemanticLabel(String name) {
    return '$name, closed journey';
  }

  @override
  String get journeyPickerCreateNewAction => 'Create a new journey';

  @override
  String get journeyQuickCreateTitle => 'New journey';

  @override
  String get journeyQuickCreateCancelAction => 'Cancel';

  @override
  String get closedJourneyConfirmTitle => 'This journey is closed';

  @override
  String closedJourneyConfirmMessage(String journeyName) {
    return '\"$journeyName\" is closed. Add this activity to it anyway?';
  }

  @override
  String get closedJourneyConfirmCancelAction => 'Cancel';

  @override
  String get closedJourneyConfirmAddAction => 'Add anyway';

  @override
  String get journeyStatsSectionTitle => 'Journey stats';

  @override
  String journeyStatsError(String error) {
    return 'Couldn\'t load journey stats: $error';
  }

  @override
  String get journeyStatsApiariesVisitedLabel => 'Apiaries visited';

  @override
  String journeyStatsApiariesVisitedValue(int done, int planned) {
    return '$done/$planned';
  }

  @override
  String get journeyStatsHivesHarvestedLabel => 'Hives harvested';

  @override
  String get journeyStatsHoneyCollectedLabel => 'Honey collected';

  @override
  String journeyStatsHoneyCollectedValue(String kg) {
    return '$kg kg';
  }

  @override
  String get journeyStatsAverageSupersLabel => 'Média alças/colmeia';

  @override
  String get journeyStatsAverageSupersNoData => 'No data yet';

  @override
  String journeyStatsMissingLabel(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count apiaries missing',
      one: '1 apiary still missing',
      zero: 'All planned apiaries visited',
    );
    return '$_temp0';
  }

  @override
  String get journeyDetailTitle => 'Journey';

  @override
  String get editJourneyAction => 'Edit journey';

  @override
  String get journeyDetailApiariesTitle => 'Apiaries';

  @override
  String get journeyDetailApiaryNameUnknown => 'Unknown apiary';

  @override
  String get journeyDetailApiaryVisitedBadge => 'Visited';

  @override
  String get journeyDetailApiaryPlannedBadge => 'Planned';

  @override
  String get journeyDetailApiaryNotVisitedYet => 'Not visited yet';

  @override
  String get journeyDetailApiariesEmpty => 'No apiaries in this journey yet.';

  @override
  String get todosEmpty => 'No todos yet.';

  @override
  String get todosFilterNoResults => 'No todos match your filters.';

  @override
  String todosError(String error) {
    return 'Could not load todos: $error';
  }

  @override
  String get todoFilterStatusLabel => 'Status';

  @override
  String get todoFilterStatusAll => 'All';

  @override
  String get todoFilterStatusOpen => 'Open';

  @override
  String get todoFilterStatusOverdue => 'Overdue';

  @override
  String get todoFilterStatusDone => 'Completed';

  @override
  String get todoFilterPriorityLabel => 'Priority';

  @override
  String get todoFilterPriorityAll => 'All priorities';

  @override
  String get todoPriorityLowLabel => 'Low';

  @override
  String get todoPriorityMediumLabel => 'Medium';

  @override
  String get todoPriorityHighLabel => 'High';

  @override
  String get todoFilterDueLabel => 'Due';

  @override
  String get todoFilterDueAny => 'Any date';

  @override
  String get todoFilterDueToday => 'Due today';

  @override
  String get todoFilterDueThisWeek => 'Due this week';

  @override
  String get todoFilterDueThisMonth => 'Due this month';

  @override
  String get todoFilterClearAction => 'Clear filters';

  @override
  String get todoSortFieldLabel => 'Sort by';

  @override
  String get todoSortFieldDueDate => 'Due date';

  @override
  String get todoSortFieldPriority => 'Priority';

  @override
  String get todoSortFieldStatus => 'Status';

  @override
  String get todoSortDirectionAscendingLabel => 'Ascending';

  @override
  String get todoSortDirectionDescendingLabel => 'Descending';

  @override
  String get todoDueDateUnset => 'No due date';

  @override
  String get todoOverdueBadge => 'Overdue';

  @override
  String todoStatusSemanticLabel(String status) {
    return 'Status: $status';
  }

  @override
  String get addTodo => 'New todo';

  @override
  String get todoQuickCreateTitle => 'New todo';

  @override
  String get newTodoTitle => 'New todo';

  @override
  String get todoDetailTitle => 'Todo';

  @override
  String get editTodoTitle => 'Edit todo';

  @override
  String get editTodoAction => 'Edit todo';

  @override
  String get todoTitleLabel => 'Title';

  @override
  String get todoTitleRequired => 'Title is required';

  @override
  String get todoDescriptionLabel => 'Description';

  @override
  String get todoDescriptionUnset => 'No description';

  @override
  String get todoDueDateFieldLabel => 'Due date';

  @override
  String get todoDueDateLabel => 'Due date';

  @override
  String get todoDueDateClearAction => 'Clear due date';

  @override
  String get todoPriorityFieldLabel => 'Priority';

  @override
  String get todoAssigneeFieldLabel => 'Assignee';

  @override
  String get todoApiaryFieldLabel => 'Apiary';

  @override
  String get todoAssigneeUnassigned => 'Unassigned';

  @override
  String todoAssigneeUnknown(String id) {
    return 'Member $id';
  }

  @override
  String get todoAssigneeNoneAvailable => 'No members available yet.';

  @override
  String get todoApiaryNone => 'No apiary';

  @override
  String get todoApiaryUnknown => 'Unknown apiary';

  @override
  String get todoDetailFieldsHeader => 'Details';

  @override
  String get todoCompletedAtLabel => 'Completed at';

  @override
  String get todoCompleteAction => 'Mark as complete';

  @override
  String get todoReopenAction => 'Reopen';

  @override
  String get todoCompleteSuccess => 'Todo marked complete';

  @override
  String todoCompleteError(String error) {
    return 'Couldn\'t update the todo: $error';
  }

  @override
  String get todoReopenSuccess => 'Todo reopened';

  @override
  String todoReopenError(String error) {
    return 'Couldn\'t update the todo: $error';
  }

  @override
  String get todoSaveSuccess => 'Todo saved';

  @override
  String todoSaveError(String error) {
    return 'Couldn\'t save the todo: $error';
  }

  @override
  String todoLoadError(String error) {
    return 'Couldn\'t load the todo: $error';
  }

  @override
  String get deleteTodo => 'Delete todo';

  @override
  String get todoDeleteSuccess => 'Todo deleted';

  @override
  String todoDeleteError(String error) {
    return 'Couldn\'t delete the todo: $error';
  }

  @override
  String get deleteTodoConfirmTitle => 'Delete todo?';

  @override
  String get deleteTodoConfirmMessage =>
      'This permanently deletes this todo. This cannot be undone.';

  @override
  String get deleteTodoConfirmAction => 'Delete';

  @override
  String get deleteTodoCancelAction => 'Cancel';

  @override
  String todoQuickCreateForApiary(String apiaryName) {
    return 'For $apiaryName';
  }

  @override
  String get todoQuickCreateCancelAction => 'Cancel';

  @override
  String get todoCreatedConfirmation => 'Todo created';
}
