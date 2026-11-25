/* GENERATED from spec/Mina/Domain.lean. Do not edit. */
#ifndef MINA_DOMAIN_H
#define MINA_DOMAIN_H

#define ROLE_CITIZEN 1
#define ROLE_RESPONDER 2
#define ROLE_ADMIN 3
#define KIND_SOS_CREATED 1
#define KIND_SOS_ACKNOWLEDGED 2
#define KIND_STATUS_UPDATED 3
#define KIND_INCIDENT_RESOLVED 4
#define KIND_SAFETY_REPORTED 5
#define KIND_ALERT_PUBLISHED 6
#define STATUS_OPEN 1
#define STATUS_ACKNOWLEDGED 2
#define STATUS_IN_PROGRESS 3
#define STATUS_RESOLVED 4
#define F_REGION 1
#define F_CATEGORY 2
#define F_STATUS 4
#define F_BODY 8
#define F_LOCATION 16
#define F_INCIDENT 32
#define F_AT 64
#define CATEGORY_MAX 5
#define MAX_REGION 1024
#define MAX_LAT 9000000
#define MAX_LON 18000000
#define MAX_TIME 99999999999
#define MAX_BODY_CHARS 280
#define MIN_SECRET_BYTES 32

typedef struct { u8 roles, restricted, need, allow, status_lo, status_hi, target; } kind_spec;
#define KIND_COUNT 7
static const kind_spec KIND_SPECS[KIND_COUNT] = {
  [1] = {.roles = 14, .restricted = 1, .need = 3, .allow = 91, .status_lo = 0, .status_hi = 0, .target = 0},  /* sos_created */
  [2] = {.roles = 12, .restricted = 0, .need = 32, .allow = 96, .status_lo = 0, .status_hi = 0, .target = 2},  /* sos_acknowledged */
  [3] = {.roles = 12, .restricted = 0, .need = 36, .allow = 100, .status_lo = 2, .status_hi = 3, .target = 0},  /* status_updated */
  [4] = {.roles = 12, .restricted = 0, .need = 32, .allow = 96, .status_lo = 0, .status_hi = 0, .target = 4},  /* incident_resolved */
  [5] = {.roles = 14, .restricted = 1, .need = 5, .allow = 93, .status_lo = 1, .status_hi = 2, .target = 0},  /* safety_reported */
  [6] = {.roles = 12, .restricted = 0, .need = 9, .allow = 73, .status_lo = 0, .status_hi = 0, .target = 0},  /* alert_published */
};
static const u8 TRANSITIONS[KIND_COUNT][5] = {
  [2] = {[1] = 4},  /* sos_acknowledged */
  [3] = {[2] = 8, [3] = 4},  /* status_updated */
  [4] = {[1] = 16, [2] = 16, [3] = 16},  /* incident_resolved */
};

#endif
