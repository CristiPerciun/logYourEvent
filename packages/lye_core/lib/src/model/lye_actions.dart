/// Catalog of action codes.
///
/// Codes are dotted, lower-case, stable identifiers (`family.verb` or
/// `family.object.verb`). Products may add their own under the `x.` prefix
/// (for example `x.privacybox.ropa.export`); everything else is reserved for
/// the library so that the verifier can reason about it.
abstract final class LyeActions {
  // Library housekeeping ----------------------------------------------------

  /// First event of every stream; links to the previous epoch of the node.
  static const String streamStart = 'lye.stream.start';

  /// The local buffer had to drop shipped events to stay within its cap.
  static const String streamOverflow = 'lye.stream.overflow';

  /// A client batch passed verification on the server.
  static const String ingestAccepted = 'lye.ingest.accepted';

  /// A client batch was refused (gap, broken link, foreign stream, too big).
  static const String ingestRejected = 'lye.ingest.rejected';

  /// A CSV file and its manifest were written.
  static const String exportWritten = 'lye.export.written';

  /// Stream heads were anchored outside the database.
  static const String anchorExported = 'lye.anchor.exported';

  /// The receiver refused a batch definitively; shipping of the stream stops.
  static const String shipRejected = 'lye.ship.rejected';

  /// Files older than their retention class were removed.
  static const String retentionPurged = 'lye.retention.purged';

  // Application lifecycle ---------------------------------------------------

  static const String appStart = 'app.start';
  static const String appResume = 'app.resume';
  static const String appPause = 'app.pause';
  static const String appDetach = 'app.detach';
  static const String appLocaleChange = 'app.locale_change';

  // Navigation --------------------------------------------------------------

  static const String navPush = 'nav.push';
  static const String navPop = 'nav.pop';
  static const String navReplace = 'nav.replace';
  static const String navRemove = 'nav.remove';

  // Interaction -------------------------------------------------------------

  static const String uiPointerDown = 'ui.pointer_down';
  static const String uiPointerUp = 'ui.pointer_up';
  static const String uiTap = 'ui.tap';

  /// A user intent expressed through a tracked control (button, menu item).
  static const String uiIntent = 'ui.intent';

  /// A form field changed. Only the field identifier is recorded, never
  /// the value.
  static const String uiFormFieldChange = 'ui.form.field_change';
  static const String uiFormSubmit = 'ui.form.submit';

  // Riverpod state ----------------------------------------------------------

  static const String stateAdd = 'state.add';
  static const String stateUpdate = 'state.update';
  static const String stateDispose = 'state.dispose';
  static const String stateFail = 'state.fail';
  static const String stateMutationStart = 'state.mutation.start';
  static const String stateMutationSuccess = 'state.mutation.success';
  static const String stateMutationError = 'state.mutation.error';

  // Remote calls ------------------------------------------------------------

  /// Client side of an endpoint call.
  static const String rpcCall = 'rpc.call';

  /// Server side of an endpoint call.
  static const String rpcHandle = 'rpc.handle';

  // Database ----------------------------------------------------------------

  /// A scoped transaction as a span: `start` at BEGIN, `end` with outcome
  /// `ok` at COMMIT or `fail` at ROLLBACK.
  static const String dbScope = 'db.scope';
  static const String dbScopeBegin = 'db.scope.begin';
  static const String dbScopeCommit = 'db.scope.commit';
  static const String dbScopeRollback = 'db.scope.rollback';
  static const String dbStatement = 'db.statement';

  // Audit log (compliance-os `audit.events`) --------------------------------

  static const String auditAppend = 'audit.append';
  static const String auditVerify = 'audit.verify';

  // Jobs --------------------------------------------------------------------

  static const String jobEnqueue = 'job.enqueue';
  static const String jobFetch = 'job.fetch';
  static const String jobComplete = 'job.complete';
  static const String jobFail = 'job.fail';
  static const String jobDeadLetter = 'job.dead_letter';

  // Identity ----------------------------------------------------------------

  static const String authLogin = 'auth.login';
  static const String authLogout = 'auth.logout';
  static const String authMfaStepUp = 'auth.mfa.step_up';
  static const String authSessionRevoke = 'auth.session.revoke';
  static const String authTenantSwitch = 'auth.tenant.switch';

  // Security ----------------------------------------------------------------

  static const String securityBreakGlass = 'security.break_glass';
  static const String securityScopeViolation = 'security.scope_violation';
  static const String securityRateLimited = 'security.rate_limited';

  // Documents and exports ---------------------------------------------------

  /// A document was displayed ("visionato", §5.6: a SELECT fires no trigger).
  static const String documentView = 'document.view';
  static const String documentDownload = 'document.download';
  static const String exportCsv = 'export.csv';

  // Errors ------------------------------------------------------------------

  static const String errorUnhandled = 'error.unhandled';
  static const String errorHandled = 'error.handled';

  /// Prefix reserved to product-specific codes.
  static const String extensionPrefix = 'x.';

  static final RegExp _wellFormed = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$');

  /// Whether [code] respects the grammar of action codes.
  static bool isWellFormed(String code) => _wellFormed.hasMatch(code);
}
