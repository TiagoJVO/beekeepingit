// GENERATED FILE — DO NOT EDIT BY HAND.
//
// Generated from contracts/validation/sync-ops.validation.json by
// scripts/gen-sync-validation.sh. Edit the JSON description and re-run that
// script; a stale copy fails
// client/test/core/validation/sync_validation_rules_test.dart in CI.
//
// The shared description (docs/architecture/sync.md §9, D-12, FR-OF-2) is the
// single definition of the mechanical sync-op validation rules. It is embedded
// here VERBATIM rather than translated into Dart literals, so the rule data on
// the client is byte-identical to the shared file and cannot silently drift
// from it. `SyncValidationRules.parse` (../sync_validation_rules.dart) turns it
// into rules; `SyncValidationRules.shared` does that once, lazily.

/// The shared sync-op validation description, verbatim.
const syncValidationRulesJson = r'''
{
  "version": 1,
  "description": "Shared validation description for sync write-back ops (docs/architecture/sync.md §9, D-12, FR-OF-2). Single definition of the MECHANICAL, offline-checkable half of the rules each owning service's validate*Op enforces (services/{apiaries,activities,journeys,todos}/api/sync.go). The server stays authoritative: rules that need server-only context (cross-org ownership lookups, the per-activity-type attribute schema) are deliberately absent here and are left entirely to the server. See contracts/validation/README.md.",
  "serverOnly": [
    "Cross-organization ownership of apiary_id / journey_id / assignee_id — needs server state the device does not have offline.",
    "The per-activity-type attribute-bag schema (services/activities/api/types.go ValidateActivity) — a rich schema, not a mechanical constraint.",
    "The extensible controlled vocabularies counter_type, main_activity_type, journey status and todo priority/status (D-20). A frozen client copy would PERMANENTLY reject a value a newer server accepts (a newer vocabulary value can reach an older client by down-sync and be re-uploaded), with no server to overrule it — the asymmetry makes mirroring them worse than not mirroring them.",
    "The 'patch must change at least one field' rules (apiary in services/apiaries/api/sync.go, stock_declaration in declarations.go) — each defined over an exact field list, so a field added server-side would make the client reject valid patches, for no user-visible benefit.",
    "A stock_declaration's breakdown snapshot (validateBreakdown, services/apiaries/api/declarations.go) — a bounded array of objects whose contents the server never reads. Its shape rules do not fit the field-check vocabulary here, and the client is the side that BUILDS it, so a client-side re-check would only restate the writer's own invariant.",
    "Batch-size and body-size caps (maxBatchOps, maxSyncBatchBodyBytes) — properties of a whole request, not of a queued edit the user can fix."
  ],
  "envelope": {
    "id": {
      "code": "invalid",
      "message": "id must be a UUID"
    },
    "updatedAt": {
      "code": "required",
      "message": "updated_at is required"
    }
  },
  "entities": {
    "apiary": {
      "source": "services/apiaries/api/sync.go validateApiaryOp",
      "ops": {
        "allowed": ["put", "patch", "delete"],
        "code": "invalid",
        "message": "op must be put, patch or delete"
      },
      "entityTypeCheck": {
        "code": "invalid",
        "message": "entity_type must be apiary, apiary_counter or stock_declaration"
      },
      "fields": [
        {
          "name": "name",
          "absentWhen": "empty",
          "checks": [
            {
              "kind": "required",
              "on": ["put"],
              "code": "required",
              "message": "name is required"
            },
            {
              "kind": "maxLength",
              "limit": 200,
              "code": "too_long",
              "message": "name must be at most 200 characters"
            }
          ]
        },
        {
          "name": "hive_count",
          "checks": [
            {
              "kind": "min",
              "limit": 0,
              "code": "out_of_range",
              "message": "hive_count must be >= 0"
            }
          ]
        },
        {
          "name": "notes",
          "checks": [
            {
              "kind": "maxLength",
              "limit": 10000,
              "code": "too_long",
              "message": "notes must be at most 10000 characters"
            }
          ]
        },
        {
          "name": "place_label",
          "checks": [
            {
              "kind": "maxLength",
              "limit": 200,
              "code": "too_long",
              "message": "place_label must be at most 200 characters"
            }
          ]
        },
        {
          "name": "registration_number",
          "checks": [
            {
              "kind": "maxLength",
              "limit": 50,
              "code": "too_long",
              "message": "registration_number must be at most 50 characters"
            }
          ]
        },
        {
          "name": "location_lon",
          "checks": [
            {
              "kind": "range",
              "min": -180,
              "max": 180,
              "code": "out_of_range",
              "message": "location_lon must be between -180 and 180",
              "onlyWithAll": ["location_lat"]
            }
          ]
        },
        {
          "name": "location_lat",
          "checks": [
            {
              "kind": "range",
              "min": -90,
              "max": 90,
              "code": "out_of_range",
              "message": "location_lat must be between -90 and 90",
              "onlyWithAll": ["location_lon"]
            }
          ]
        }
      ],
      "entityChecks": [
        {
          "kind": "requiredGroup",
          "on": ["put"],
          "fields": ["location_lon", "location_lat"],
          "reportAs": "location",
          "code": "required",
          "message": "location is required"
        },
        {
          "kind": "requiredWhenPresent",
          "whenPresent": "location_lon",
          "require": "location_lat",
          "code": "required",
          "message": "location_lat is required when location_lon is set"
        },
        {
          "kind": "requiredWhenPresent",
          "whenPresent": "location_lat",
          "require": "location_lon",
          "code": "required",
          "message": "location_lon is required when location_lat is set"
        }
      ]
    },
    "apiary_counter": {
      "source": "services/apiaries/api/sync.go validateCounterOp",
      "ops": {
        "allowed": ["put", "patch"],
        "code": "invalid",
        "message": "op must be put or patch for apiary_counter (counters have no delete)"
      },
      "fields": [
        {
          "name": "apiary_id",
          "checks": [
            {
              "kind": "required",
              "on": ["put", "patch"],
              "code": "required",
              "message": "apiary_id is required"
            },
            {
              "kind": "uuid",
              "code": "invalid",
              "message": "apiary_id must be a UUID"
            }
          ]
        },
        {
          "name": "counter_type",
          "checks": [
            {
              "kind": "required",
              "on": ["put", "patch"],
              "code": "required",
              "message": "counter_type is required"
            }
          ]
        },
        {
          "name": "value",
          "checks": [
            {
              "kind": "required",
              "on": ["put"],
              "code": "required",
              "message": "value is required"
            },
            {
              "kind": "min",
              "limit": 0,
              "code": "out_of_range",
              "message": "value must be >= 0"
            }
          ]
        }
      ]
    },
    "stock_declaration": {
      "source": "services/apiaries/api/declarations.go validateDeclarationOp",
      "ops": {
        "allowed": ["put", "patch", "delete"],
        "code": "invalid",
        "message": "op must be put, patch or delete"
      },
      "fields": [
        {
          "name": "declared_on",
          "checks": [
            {
              "kind": "required",
              "on": ["put"],
              "code": "required",
              "message": "declared_on is required"
            },
            {
              "kind": "date",
              "code": "invalid",
              "message": "declared_on must be a date in YYYY-MM-DD form"
            }
          ]
        },
        {
          "name": "total_hive_count",
          "checks": [
            {
              "kind": "required",
              "on": ["put"],
              "code": "required",
              "message": "total_hive_count is required"
            },
            {
              "kind": "min",
              "limit": 0,
              "code": "out_of_range",
              "message": "total_hive_count must be >= 0"
            }
          ]
        },
        {
          "name": "registration_number",
          "checks": [
            {
              "kind": "maxLength",
              "limit": 50,
              "code": "too_long",
              "message": "registration_number must be at most 50 characters"
            }
          ]
        },
        {
          "name": "notes",
          "checks": [
            {
              "kind": "maxLength",
              "limit": 2000,
              "code": "too_long",
              "message": "notes must be at most 2000 characters"
            }
          ]
        }
      ]
    },
    "activity": {
      "source": "services/activities/api/sync.go validateActivityOp",
      "ops": {
        "allowed": ["put", "patch", "delete"],
        "code": "invalid",
        "message": "op must be put, patch or delete"
      },
      "entityTypeCheck": {
        "code": "invalid",
        "message": "entity_type must be activity"
      },
      "fields": [
        {
          "name": "apiary_id",
          "checks": [
            {
              "kind": "required",
              "on": ["put"],
              "code": "required",
              "message": "apiary_id is required"
            },
            {
              "kind": "uuid",
              "code": "invalid",
              "message": "apiary_id must be a UUID"
            }
          ]
        },
        {
          "name": "occurred_at",
          "absentWhen": "empty",
          "checks": [
            {
              "kind": "required",
              "on": ["put"],
              "code": "required",
              "message": "occurred_at is required"
            },
            {
              "kind": "date",
              "code": "invalid",
              "message": "occurred_at must be a YYYY-MM-DD date"
            }
          ]
        },
        {
          "name": "attributes",
          "checks": [
            {
              "kind": "jsonObject",
              "code": "invalid",
              "message": "attributes must be a JSON object"
            }
          ]
        },
        {
          "name": "type",
          "absentWhen": "empty",
          "checks": [
            {
              "kind": "required",
              "on": ["put"],
              "code": "required",
              "message": "type is required"
            }
          ]
        },
        {
          "name": "journey_id",
          "checks": [
            {
              "kind": "uuid",
              "code": "invalid",
              "message": "journey_id must be a UUID"
            }
          ]
        }
      ]
    },
    "journey": {
      "source": "services/journeys/api/sync.go validateJourneyOp",
      "ops": {
        "allowed": ["put", "patch", "delete"],
        "code": "invalid",
        "message": "op must be put, patch or delete"
      },
      "entityTypeCheck": {
        "code": "invalid",
        "message": "entity_type must be journey or journey_plan_item"
      },
      "fields": [
        {
          "name": "name",
          "absentWhen": "empty",
          "checks": [
            {
              "kind": "required",
              "on": ["put"],
              "code": "required",
              "message": "name is required"
            },
            {
              "kind": "maxLength",
              "limit": 200,
              "code": "too_long",
              "message": "name must be at most 200 characters"
            }
          ]
        },
        {
          "name": "main_activity_type",
          "checks": [
            {
              "kind": "required",
              "on": ["put"],
              "code": "required",
              "message": "main_activity_type is required"
            }
          ]
        },
        {
          "name": "default_attributes",
          "checks": [
            {
              "kind": "maxBytes",
              "limit": 8192,
              "code": "too_long",
              "message": "default_attributes must be at most 8192 bytes"
            },
            {
              "kind": "jsonObject",
              "code": "invalid",
              "message": "default_attributes must be a JSON object"
            }
          ]
        }
      ]
    },
    "journey_plan_item": {
      "source": "services/journeys/api/sync.go validateJourneyPlanItemOp",
      "ops": {
        "allowed": ["put", "delete"],
        "code": "invalid",
        "message": "op must be put or delete for journey_plan_item (plan items have no patch)"
      },
      "fields": [
        {
          "name": "journey_id",
          "checks": [
            {
              "kind": "required",
              "on": ["put", "patch"],
              "code": "required",
              "message": "journey_id is required"
            },
            {
              "kind": "uuid",
              "code": "invalid",
              "message": "journey_id must be a UUID"
            }
          ]
        },
        {
          "name": "apiary_id",
          "checks": [
            {
              "kind": "required",
              "on": ["put", "patch"],
              "code": "required",
              "message": "apiary_id is required"
            },
            {
              "kind": "uuid",
              "code": "invalid",
              "message": "apiary_id must be a UUID"
            }
          ]
        }
      ]
    },
    "todo": {
      "source": "services/todos/api/sync.go validateTodoOp",
      "ops": {
        "allowed": ["put", "patch", "delete"],
        "code": "invalid",
        "message": "op must be put, patch or delete"
      },
      "entityTypeCheck": {
        "code": "invalid",
        "message": "entity_type must be todo"
      },
      "fields": [
        {
          "name": "title",
          "absentWhen": "blank",
          "checks": [
            {
              "kind": "required",
              "on": ["put"],
              "code": "required",
              "message": "title is required"
            },
            {
              "kind": "maxLength",
              "limit": 500,
              "code": "too_long",
              "message": "title must be at most 500 characters"
            }
          ]
        },
        {
          "name": "description",
          "checks": [
            {
              "kind": "maxLength",
              "limit": 10000,
              "code": "too_long",
              "message": "description must be at most 10000 characters"
            }
          ]
        },
        {
          "name": "due_date",
          "absentWhen": "empty",
          "checks": [
            {
              "kind": "date",
              "code": "invalid",
              "message": "due_date must be a YYYY-MM-DD date"
            }
          ]
        },
        {
          "name": "priority",
          "checks": [
            {
              "kind": "required",
              "on": ["put"],
              "code": "required",
              "message": "priority is required"
            }
          ]
        },
        {
          "name": "completed_at",
          "absentWhen": "empty",
          "checks": [
            {
              "kind": "dateTime",
              "code": "invalid",
              "message": "completed_at must be an RFC3339 timestamp"
            }
          ]
        },
        {
          "name": "assignee_id",
          "absentWhen": "empty",
          "checks": [
            {
              "kind": "uuid",
              "code": "invalid",
              "message": "assignee_id must be a UUID"
            }
          ]
        },
        {
          "name": "apiary_id",
          "absentWhen": "empty",
          "checks": [
            {
              "kind": "uuid",
              "code": "invalid",
              "message": "apiary_id must be a UUID"
            }
          ]
        }
      ]
    }
  }
}
''';
