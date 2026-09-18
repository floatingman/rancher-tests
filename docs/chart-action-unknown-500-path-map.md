# Phase 2 — Path map: proxied chart-action POST and the `500 ("unknown")` signature (rancher/tests#918)

Static analysis of `rancher/rancher` across `release/v2.13`, `release/v2.14`, `release/v2.15` (+ `main` HEAD spot-checks),
2026-09-18. Method: five parallel read-only recon passes over GitHub at exact refs (per-line catalog handler maps, proxy/tunnel
layer, commit/issue history, client-go rendering). Every quoted string was read from the named ref; `[INFERENCE]` marks the rest.
Full per-line error-site tables (52 + 74 + ~45 rows) live in the session artifacts `local://phase2-line-v{213,214,215}.md`,
`local://phase2-proxy.md`, `local://phase2-history.md`; this document is the merged, ranked map that Phase 4 consumes.

## 1. Verdicts up front

1. **The chart-action handler executes in the cattle-cluster-agent pod on the downstream cluster**, inside steve's
   apiserver error funnel — not in the management rancher pods. Phase 4 must pull **cattle-cluster-agent logs** first.
2. **`("unknown")` does NOT require an empty or unparseable body.** Verified at client-go v0.36.4 (`rest/request.go`):
   any complete 500 response whose Content-Type is not `text/*` (e.g. `application/json`) and whose body is not a k8s
   `Status` renders as `an error on the server ("unknown") has prevented the request from succeeding`. The downstream
   funnel's JSON (`{"type":"error",...}`) is exactly such a body. **Every 500 from the downstream chart-action handler
   renders as `("unknown")` to a client-go-based client.**
3. **No code path in the downstream handler funnel can emit an empty-body or empty-message 500** on any of the three
   lines (verified for apiserver v0.7.9 / v0.8.8 / v0.9.10 `ErrorHandler`). The funnel always writes well-formed JSON;
   empty `message` occurs only for bare `validation.ErrorCode` writes, which are 401/404, never 500.
4. Conversely, **the rancher-side proxy sinks that return plain text render WITH their text**, not `("unknown")`:
   `errorResponder.Error` writes `err.Error()` with no Content-Type, Go's server sniffs `text/plain`, and client-go
   then substitutes the body text (verified: `isTextResponse` true for `text/*` and for empty header). So a literal
   `("unknown")` argues AGAINST the proxy-level sinks (dial failure, impersonation token, not-provisioned) and FOR the
   downstream handler funnel.
5. Therefore the ranked candidate set for the observed signature is the **action-only subset of downstream handler
   500s** (§6, candidates A1-A4), with transport-level truncation (candidate B) as the only true empty/unparseable-body
   mechanism, and rancher-side plain-text 500s (candidate C) as the churn-adjacent family that would render
   differently. This updates the Phase-2 plan's original ranking: three of its five candidates are now demoted or
   ruled out on evidence (§7).

## 2. Where the handler runs (decisive for Phase 4)

`/k8s/clusters/<id>/v1/...` is forwarded **verbatim** over the remotedialer tunnel
(`pkg/clusterrouter/proxy/proxy_server.go:RemoteService.ServeHTTP` → `proxy.NewUpgradeAwareHandler` against
`cluster.Status.APIEndpoint` with `DialContext = factory.ClusterDialer(cluster, true)`). The catalog action code
(`pkg/api/steve/catalog`, `pkg/catalogv2/helmop`) is the same rancher source compiled into the agent image; the steve
repo itself contains no catalog action code. Log-source consequences:

| Hop | Process that logs it |
|---|---|
| Router/proxy/tunnel/impersonation sinks 1-12 | **rancher management pods** |
| `action=install` dispatch, helmop, Operation CR, helm-operation pod | **cattle-cluster-agent pod** (steve) |
| Funnel log line `Unknown error: <err>` | **cattle-cluster-agent pod** (steve's apiserver) |

## 3. Client rendering semantics (verified, client-go v0.36.4 `rest/request.go`)

- `transformResponse` reads the full body; non-2xx → `newUnstructuredResponseError(body, isTextResponse(resp), ...)`.
- `newUnstructuredResponseError`: `message := "unknown"`; replaced by the body text **only if** `isTextResponse`.
- `isTextResponse`: true when `Content-Type` is empty OR starts with `text/`; false for `application/json`.
- `Result.Error()` tries to decode the body as `metav1.Status`; rancher's funnel JSON (`type: error`, no `kind`) fails
  to decode ("Body was not decodable" at V5) → the generic error stands.
- Mid-body connection abort takes a different branch entirely (`http2.StreamError` → `stream error when reading
  response body...`; other read errors → `unexpected error when reading response body...`) — **not** `("unknown")`.
- Exact final format string comes from apimachinery `errors.NewGenericServerResponse`
  (`an error on the server ("%s") has prevented the request from succeeding`) [INFERENCE on exact wording; call site
  verified].

| Response seen by client | client-go rendering |
|---|---|
| 500 `application/json` `{"type":"error","status":500,...}` (downstream funnel) | `("unknown")` — **matches observed signature** |
| 500 plain text, sniffed `text/plain` (proxy `errorResponder`: dial failure, impersonation token, `Unauthorized 401`) | body text quoted, e.g. `("cluster agent disconnected")` |
| 500 JSON with Content-Type header LOST (`router.go:response()` writes header before setting content-type) | raw JSON treated as text → rendered text = the JSON itself |
| 500 empty body, no Content-Type | `("")` — no known producer (§7) |
| Truncated/aborted mid-body | stream-error message, not `("unknown")` |

## 4. Full call chain with per-hop status/body semantics

```
client POST /k8s/clusters/<id>/v1/catalog.cattle.io.clusterrepos/rancher-charts?action=install
 │  (all three lines; behavior identical unless noted)
 ├─ [H1] Router.ServeHTTP (pkg/clusterrouter/router.go)
 │      factory.get err → response(500, JSON {"Code":...}, Content-Type header LOST, never empty)
 │      not provisioned → 503 JSON "cluster not provisioned" (creation-time check only, then cached — cannot flap)
 │      no cluster     → 404 JSON "No cluster available"
 ├─ [H2] RemoteService.ServeHTTP (pkg/clusterrouter/proxy/proxy_server.go)      ← management side
 │      per-request impersonation gates → errorResponder 500 PLAIN TEXT (never empty; renders with text):
 │        "unable to create token for impersonated ServiceAccount: ..." (TokenRequest, mgmt→downstream via tunnel)
 │        "unable to create impersonator account: error getting service account token: ..." (pkg/impersonation)
 │      transport build: NewUpgradeAwareHandler(..., errorResponder)
 ├─ [H3] tunnel dial (pkg/dialer/factory.go + remotedialer v0.6.0/v0.6.1)
 │      no session, retry ≈30s → 500 plain "cluster agent disconnected"
 │      HasSession→dial TOCTOU → 500 plain "failed to find Session for client <cluster-id>" (instant)
 ├─ [H4] mid-request tunnel break (apimachinery upgradeaware.go: ReverseProxy copy fail → panic(http.ErrAbortHandler))
 │      status+partial body already sent → aborted conn; client sees stream-error, NOT ("unknown")
 └─ downstream cluster: cattle-cluster-agent steve (rancher/apiserver funnel)
      ├─ [H5] apiserver router (ValidateAction): unregistered verb → 403 {"...","code":"PermissionDenied",
      │        "message":"no such action <verb>"}; 422 InvalidAction and 200-empty branches are dead code (all lines)
      ├─ [H6] operation.ServeHTTP (pkg/api/steve/catalog/operation.go; byte-identical 2.14↔2.15, frozen since 2024-05-15)
      │      no user → 401 message:"" (silent); install/upgrade/uninstall → helmop; success → 201 chartActionOutput
      └─ [H7] helmop (pkg/catalogv2/helmop/operation.go, v2.15 adds pull_secrets.go)
             getSpec (ClusterRepo Get) → content.Index (ConfigMap; owner-UID mismatch → 401 message:"" silent)
             → getChartCommand (index.Get / tgz fetch / gzip+tar+yaml) → createNamespace (30s RBAC watch)
             → Impersonator.CreatePod (steve podimpersonation: ClusterRole, SA, token Secret, ConfigMaps, Pod)
             → cmds.Render/CommandArgs → Operation CR Create/UpdateStatus → createRoleAndRoleBindings
             → (v2.15, repo literally named "rancher-charts" + SDR set) pull_secrets managePullSecrets
             EVERY return err → ErrorHandler → 500 JSON {"type":"error","status":500,"code":"ServerError",
             "message":err.Error()} → renders to clients as ("unknown")
```

Zero `logrus` calls exist in `pkg/catalogv2/helmop/operation.go` on **all three lines** (2.15's `pull_secrets.go` is the
exception: 11 `log.Errorf("[helmop] ...")` sites). The ONLY agent-side trace of a failed action on 2.13/2.14 is the
funnel's `logrus.Errorf("Unknown error: %v", err)`; v2.15 is the same except the `[helmop]` lines.

## 5. Pins per line (verified from each branch's go.mod)

| Component | 2.13 | 2.14 | 2.15 |
|---|---|---|---|
| rancher/steve | v0.7.47 | v0.8.28 | v0.9.23 |
| rancher/apiserver | v0.7.9 | v0.8.8 | v0.9.10 |
| rancher/wrangler/v3 | v3.3.5 | v3.6.1 | v3.7.2 |
| helm fork | v3.19.0-rancher1 | v3.20.0-rancher1 | helm/v4 v4.2.2 |
| rancher/remotedialer | v0.6.0 | n/r (spine byte-identical 2.13↔2.15) | v0.6.1 |
| steve impersonation flow | legacy SA + token Secret, unbounded 2s poll | podimpersonation, unbounded 2s poll; `waitForServiceAccount` dead code | podimpersonation: 30s `waitForServiceAccount` AND a residual unbounded poll path |

## 6. Candidate-origin table (ranked for the observed signature)

Signature being explained: `POST .../clusterrepos/rancher-charts?action=install` → 500, client reports `("unknown")`,
reads keep working, intermittent, observed on v2.15.0-rc1 (live trial 2026-09-18).

| # | Candidate origin | file:symbol (line) | Condition | Log line to grep (where) | Phase-4 observation that confirms / denies |
|---|---|---|---|---|---|
| A1 | 30s RBAC role-watch timeout ("failed to wait for roles to be populated") — install/upgrade with projectID only; action-only by construction; upstream removed it on `main` (now warns and proceeds) = acknowledged bug | `pkg/catalogv2/helmop/operation.go:createNamespace` (all three lines) | new project-scoped namespace whose `InitialRolesPopulated` lags >30s | message IS the body; funnel logs `Unknown error: failed to wait for roles to be populated` in **cattle-cluster-agent** | `Unknown error:` line present with this text ⇒ confirmed. ~30s POST latency before the 500 corroborates. Denies if absent |
| A2 | helm-operation pod impersonation machinery failure (ClusterRole / SA / token Secret / ConfigMaps / Pod create) — the action-only hop; matches observed RBAC/SA churn adjacent to the window | steve `pkg/podimpersonation/podimpersonation.go:createPod` (v0.8.28/v0.9.23; v0.7.47 legacy flow) | downstream RBAC/SA/token-controller hiccup at POST time | `Unknown error: <k8s err>` in **cattle-cluster-agent** (handler itself logs nothing) | `Unknown error:` naming clusterroles/serviceaccounts/secrets/pods ⇒ confirmed. Debug `wait for svc account secret to be populated with token` marks the poll path |
| A3 | Operation CR create / UpdateStatus failure (forbidden, namespace terminating, name collision) — action-only; pod already exists ⇒ orphaned pod + role per failure | `pkg/catalogv2/helmop/operation.go:createOperation` (all lines) | downstream API/admission error on `operations.catalog.cattle.io` | `Unknown error: operations.catalog.cattle.io "..." ...` in **cattle-cluster-agent**; orphan `helm-operation-*` pods in the window | `Unknown error:` naming the Operation CR ⇒ confirmed; orphaned pods corroborate |
| A4 | v2.15-only pull-secrets block — activates ONLY for a repo literally named `rancher-charts` with `systemDefaultRegistry` set; matches the observed failing URL exactly. Per-request opt-out exists: `?skipPullSecrets=true` query param | `pkg/catalogv2/helmop/pull_secrets.go` (2.15 only; created 2026-06-05, fix 2026-06-10) | SDR set + managed pull secrets present | 11 sites: `log.Errorf("[helmop] createNamespaceAndPullSecrets: ...")`, `[helmop] managePullSecrets: ...`, `[helmop] deleteStaleHelmOpSecrets: ...`, `[helmop] injectPullSecrets: ...` in **cattle-cluster-agent** | Any `[helmop]` error line during a failing POST ⇒ confirmed and site-identified. Total absence of `[helmop]` lines ⇒ block skipped or not the cause. Experiment: retry the same POST with `&skipPullSecrets=true` — success would isolate the block |
| B  | Mid-request tunnel break (`http.ErrAbortHandler`) — the ONLY true empty/truncated-body mechanism on the path; long-lived action POSTs (pod create + 30s watches) have orders of magnitude more exposure than sub-second reads | apimachinery `upgradeaware.go:ServeHTTP` copy loop (v0.34.9/v0.36.4 flow-identical) | agent websocket drops mid-response | rancher mgmt stderr: `suppressing error for /k8s/clusters/...` or `http: panic serving`; remotedialer Info `Handling backend connection request [...]` churn | Client sees stream-error/truncated body rather than literal `("unknown")` for mid-body breaks [verified client-go branch]; a break landing between headers and body still yields `("unknown")`. Mgmt stderr lines in the window ⇒ confirmed |
| C  | Rancher-side impersonation-token 500s (`unable to create token for impersonated ServiceAccount` / `unable to create impersonator account: ...`) — per-request, both reads and actions; would render WITH text, not `("unknown")` | `pkg/clusterrouter/proxy/proxy_server.go` tokenCreator + `pkg/impersonation/impersonation.go` (byte-identical 2.13↔2.15) | TokenRequest / impersonator SA creation failure, itself tunneled | body text = the error; debug-only impersonation logs (`impersonation: creating service account ...`) in **rancher mgmt** | Exact body capture showing these strings ⇒ confirmed as the window's failure (but predicts a text-rendered error, contradicting literal `("unknown")`) |
| D  | Dial failure family: `cluster agent disconnected` (~30s hang then 500) / `failed to find Session for client <id>` (TOCTOU, instant) — text-rendered, and reads would fail in the same window | `pkg/dialer/factory.go:ClusterDialer`, remotedialer `session_manager.go:getDialer` | agent disconnect/reconnect churn | debug: `No active connection for cluster [%s], will wait for about 30 seconds`; body text carries the strings; Info: `Handling backend connection request` churn | ~30s POST latency + disconnects in window ⇒ confirmed family; literal `("unknown")` ⇒ argues against |

Latency is a cheap discriminator: A1 ≈ exactly 30s; D-disconnect ≈ up to 30s (jittered 4×5s); C/D-TOCTOU instant;
B = arbitrary progress point; A2/A3/A4 ≈ seconds.

## 7. Ruled out (evidence)

| Hypothesis | Why ruled out |
|---|---|
| ErrorResponder 500 with EMPTY body (`err.Error()==""`) | No producer: every error on the path wraps non-empty `fmt.Errorf` prefixes or k8s/stdlib text (proxy artifact, sink 12) |
| apiserver ErrorHandler emitting an empty-message 500 | Verified at v0.7.9/v0.8.8/v0.9.10: raw errors → `message=err.Error()`; bare ErrorCodes → 401/404 only |
| `getSpec` panic (`panic("namespace should be empty")`) via ClusterRepo URL | `nsAndName` forces `namespace=""` for `catalog.cattle.io.clusterrepos` (all lines); reachable only via namespaced `Repo` actions; a panic aborts the connection anyway (no 500, no `("unknown")`) |
| Cluster-not-provisioned 503 flapping | `NewRemote` checks `ClusterConditionProvisioned` once at creation under `serverLock`; the handler is cached in `factory.servers` — warmed clusters cannot intermittently 503 on this check |
| Unregistered verb | 403 `PermissionDenied "no such action <verb>"` via `CanAction` before the handler (all three apiserver lines verified); 422/200-empty branches dead code |
| Upgrade-path empty-body 502 | Structurally unreachable: chart POSTs carry no `Upgrade` header |
| `("unknown")` caused by `router.go:response()` JSON | Content-Type header is lost (WriteHeader-first), so client-go treats the body as TEXT and renders the JSON itself, not `("unknown")` |

## 8. Narrow-surface consistency check (why reads kept working while action POSTs failed)

Reads (GET clusterrepos, index downloads) traverse H1-H3 + H5 and steve's read paths; they skip H6's action dispatch,
ALL of H7: `getSpec`→`createOperation` (CreatePod impersonation, Operation CR, 30s role watch, pull secrets, RBAC role
creation). The rancher-side per-request impersonation/token gates (H2) evaluate identically for reads and actions
(proxy artifact), and no clusterrouter/remotedialer sink distinguishes action from read. Conclusions:

1. A recurring, action-ONLY failure with healthy reads points at the action-specific downstream code (A1-A4), which
   is also exactly the set that renders as `("unknown")` (§3). This is the likeliest family.
2. Transient transport breaks (B) bias toward actions mechanically: an action POST stays in flight for seconds to
   30+s (pod create, watches), so its exposure window to a tunnel drop is orders of magnitude larger than a
   millisecond read. Reads failing in the SAME window would corroborate B; their continued health argues for family A.
3. C/D produce text-rendered bodies and affect reads equally — inconsistent with both the literal signature and the
   narrow surface.

## 9. 2.14 → 2.15 delta

- **Dispatch layer frozen**: `pkg/api/steve/catalog/{operation,catalog}.go` have byte-identical commit lists on both
  lines; newest commit 2024-05-15. No dispatch/funnel change in 2.15.
- **Proxy layer at parity**: `pkg/clusterrouter/proxy/proxy_server.go` shares one commit spine from 2026-02-21 down;
  the only branch-specific commits are same-day backport pairs — `5da85bf`/`0e79cc8` "Restrict cluster-impersonation"
  (2026-07-13; drops impersonation-header forwarding, SAR verification management-only) and `a28b0b7`/`0303a83`
  "treat disconnected like all other errors" (2026-04-10). `router.go`/`factory.go`/`impersonation.go` byte-identical.
- **The only 2.15-exclusive error-surface delta is `pkg/catalogv2/helmop/`**: `pull_secrets.go` created 2026-06-05
  (`8ad88ea`, SDR pull-secret support; follow-up fix `105578e` 2026-06-10), private-registry support for
  imported/hosted clusters (`2b467ec`, 2026-06-01 — the trial's cluster type), server-side install flag landed twice
  (`2c7a817`, `211b4af`), k8s libs to 1.36. All 2-4 months before the failing rc.
- **`main` removes the A1 failure mode** (30s role-wait now warns and proceeds) — upstream treats it as a bug.
- No prior rancher/rancher issue documents the #918 signature; #37070 (2022, "an error on the server" on
  helm-operation machinery) and #34824 (impersonator-account creation failure) corroborate long-standing fragility of
  the A2/C machinery.
- Version-line exclusivity (old H2) is dead as a required condition (reproduced on v2.15.0-rc1); if the failure IS
  strictly 2.15-only, A4 is the only new code in the window and the `managePullSecrets` feature flag is the obvious
  experiment lever.

## 10. Phase-4 observation playbook

Step 1 — **cattle-cluster-agent logs** (steve) during a failing POST:
- `Unknown error:` present → message identifies the exact site (map to §6/A1-A3 or the per-line tables).
- `[helmop]` error lines present → A4, site-identified.
- Neither present → NOT the downstream handler: go to step 2. Also check `http: panic serving`
  (panic path; unreachable via ClusterRepo, so a hit means a namespaced Repo URL) and debug-level
  `wait for svc account secret to be populated with token` (hang path: client timeout, no 500 at all).

Step 2 — **rancher management pods**:
- stderr: `suppressing error for /k8s/clusters/` / `http: panic serving` → B (tunnel break).
- Capture the failing response body verbatim: plain-text bodies map to C/D by exact string
  (`cluster agent disconnected`, `failed to find Session for client <id>`,
  `unable to create token for impersonated ServiceAccount: ...`, `unable to create impersonator account: ...`,
  503 `cluster not provisioned`); JSON `{"Code":...}` → router sink (renders as raw JSON text).
- Latency: ~30s → A1 or D-disconnect; instant → C/D-TOCTOU; arbitrary → B; seconds → A2/A3/A4.

Step 3 — classification: literal `("unknown")` + healthy reads + action-only ⇒ family A (A1 first: single grep,
30s latency, known-flaky, upstream-acknowledged on main).

## 11. Sources

- Per-line maps: `local://phase2-line-v213.md` (52 rows), `local://phase2-line-v214.md` (74 rows),
  `local://phase2-line-v215.md` (52 rows incl. pull_secrets), `local://phase2-proxy.md` (13 sinks + verdicts),
  `local://phase2-history.md` (107 commit rows, 15 flagged, issue sweep).
- Rendering: k8s.io/client-go@v0.36.4 `rest/request.go` (`transformResponse`, `newUnstructuredResponseError`,
  `isTextResponse`, `Result.Error`) — read and quoted this session.
- All rancher/apiserver/steve/wrangler/remotedialer quotes verified at the exact refs in §5.
