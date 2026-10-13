package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var now = time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)

const catalogPath = "../../access-requests/catalog.yaml"

func mustCatalog(t *testing.T) *Catalog {
	t.Helper()
	c, err := loadCatalog(catalogPath)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func writeReq(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "req.yaml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

const base = `apiVersion: ridgeline.dev/v1alpha1
kind: AccessRequest
metadata:
  name: test-req
spec:
  requester: dev@example.com
  ticket: PLAT-1
  environment: %ENV%
  subject: identity/verify-api
  expires: "%EXP%"
  justification: needs this for the new verification flow
  %EXTRA%
  grants:
%GRANTS%
`

func req(env, exp, extra, grants string) string {
	return strings.NewReplacer("%ENV%", env, "%EXP%", exp, "%EXTRA%", extra, "%GRANTS%", grants).Replace(base)
}

func validate(t *testing.T, body string) (*Plan, error) {
	t.Helper()
	r, err := loadRequest(writeReq(t, body))
	if err != nil {
		t.Fatal(err)
	}
	return Validate(r, mustCatalog(t), now)
}

func wantProblem(t *testing.T, err error, substr string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), substr) {
		t.Fatalf("want problem containing %q, got %v", substr, err)
	}
}

func TestExamplesInRepoAreValid(t *testing.T) {
	paths, err := expand([]string{"../../access-requests"})
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range paths {
		r, err := loadRequest(p)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := Validate(r, mustCatalog(t), now); err != nil {
			t.Errorf("%s: %v", p, err)
		}
	}
}

func TestRejectsWildcardsAndUnlistedActions(t *testing.T) {
	_, err := validate(t, req("staging", "2026-10-30", "", "    - resource: sqs/verification-events\n      actions: [\"sqs:*\", sqs:PurgeQueue]"))
	wantProblem(t, err, "wildcard")
	wantProblem(t, err, `"sqs:PurgeQueue" is not grantable`)
}

func TestExpiryIsRequiredAndBoundedPerEnvironment(t *testing.T) {
	g := "    - resource: svc/risk-scorer"
	_, err := validate(t, req("staging", "never", "", g))
	wantProblem(t, err, "standing access is not allowed")
	_, err = validate(t, req("staging", "2027-01-01", "", g))
	wantProblem(t, err, "maximum for staging")
	_, err = validate(t, req("prod", "2026-10-30", "", g))
	wantProblem(t, err, "maximum for prod")
	_, err = validate(t, req("staging", "2026-10-01", "", g))
	wantProblem(t, err, "in the past")
}

func TestPIIOutsideProdNeedsRiskExceptionAndShortWindow(t *testing.T) {
	g := "    - resource: s3/verification-records\n      actions: [s3:GetObject]"
	_, err := validate(t, req("dev", "2026-10-20", "", g))
	wantProblem(t, err, "risk exception")

	_, err = validate(t, req("dev", "2026-11-30", "riskException: RAE-2026-001", g))
	wantProblem(t, err, "limited to 14 days")

	plan, err := validate(t, req("dev", "2026-10-20", "riskException: RAE-2026-001", g))
	if err != nil {
		t.Fatal(err)
	}
	if !contains(plan.Approvers, "@ridgeline/security") {
		t.Fatalf("PII grant must route to security, got %v", plan.Approvers)
	}
}

func TestApproversFollowResourceOwnership(t *testing.T) {
	plan, err := validate(t, req("staging", "2026-10-30", "", "    - resource: svc/risk-scorer\n    - resource: sqs/verification-events\n      actions: [sqs:SendMessage]"))
	if err != nil {
		t.Fatal(err)
	}
	// risk owns risk-scorer -> risk must approve; identity owns the queue and
	// is the requester's own team -> no extra approver.
	got := strings.Join(plan.Approvers, ",")
	if got != "@ridgeline/platform,@ridgeline/risk" {
		t.Fatalf("approvers = %s", got)
	}
}

func TestStrictParsingCatchesTypos(t *testing.T) {
	body := strings.Replace(req("staging", "2026-10-30", "", "    - resource: svc/risk-scorer"), "ticket:", "tikcet:", 1)
	if _, err := loadRequest(writeReq(t, body)); err == nil {
		t.Fatal("expected unknown-field error")
	}
}

func TestRenderIAMIsLeastPrivilege(t *testing.T) {
	plan, err := validate(t, req("staging", "2026-10-30", "", "    - resource: dynamodb/risk-signals\n      actions: [dynamodb:Query, dynamodb:GetItem]"))
	if err != nil {
		t.Fatal(err)
	}
	out, err := RenderIAM(plan)
	if err != nil {
		t.Fatal(err)
	}
	var tf struct {
		Resource struct {
			Policy map[string]struct {
				Policy string            `json:"policy"`
				Tags   map[string]string `json:"tags"`
			} `json:"aws_iam_policy"`
			Attach map[string]struct {
				Role string `json:"role"`
			} `json:"aws_iam_role_policy_attachment"`
		} `json:"resource"`
	}
	if err := json.Unmarshal(out, &tf); err != nil {
		t.Fatal(err)
	}
	p := tf.Resource.Policy["test_req"]
	var doc iamPolicy
	if err := json.Unmarshal([]byte(p.Policy), &doc); err != nil {
		t.Fatal(err)
	}
	st := doc.Statement[0]
	if strings.Join(st.Action, ",") != "dynamodb:GetItem,dynamodb:Query" {
		t.Fatalf("actions = %v", st.Action)
	}
	if st.Resource[0] != "arn:aws:dynamodb:us-east-1:222222222222:table/staging-risk-signals" {
		t.Fatalf("resource = %v", st.Resource)
	}
	if p.Tags["ticket"] != "PLAT-1" || p.Tags["expires"] != "2026-10-30" {
		t.Fatalf("audit tags missing: %v", p.Tags)
	}
	if tf.Resource.Attach["test_req"].Role != "staging-identity-verify-api" {
		t.Fatalf("role = %v", tf.Resource.Attach)
	}
}

func TestRenderNetworkOpensBothSides(t *testing.T) {
	plan, err := validate(t, req("staging", "2026-10-30", "", "    - resource: svc/risk-scorer"))
	if err != nil {
		t.Fatal(err)
	}
	nps, _ := RenderNetwork(plan)
	if len(nps) != 2 {
		t.Fatalf("want egress+ingress, got %d", len(nps))
	}
	ns := []string{nps[0]["metadata"].(obj)["namespace"].(string), nps[1]["metadata"].(obj)["namespace"].(string)}
	if ns[0] != "identity" || ns[1] != "risk" {
		t.Fatalf("namespaces = %v", ns)
	}
	names := []string{nps[0]["metadata"].(obj)["name"].(string), nps[1]["metadata"].(obj)["name"].(string)}
	if names[0] != "access-test-req-svc-risk-scorer-egress" || names[1] != "access-test-req-svc-risk-scorer-ingress" {
		t.Fatalf("names = %v", names)
	}
}

func TestCLIRenderRefusesInvalid(t *testing.T) {
	p := writeReq(t, req("staging", "2026-10-30", "", "    - resource: svc/nope"))
	var out, errb bytes.Buffer
	code := run([]string{"render", "-catalog", catalogPath, "-out", t.TempDir(), p}, &out, &errb, now)
	if code != 1 || !strings.Contains(errb.String(), "refusing to render") {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
}

func TestCLIExpired(t *testing.T) {
	soon := writeReq(t, req("staging", "2026-10-12", "", "    - resource: svc/risk-scorer"))
	var out bytes.Buffer
	run([]string{"expired", soon}, &out, &bytes.Buffer{}, now)
	if out.Len() != 0 {
		t.Fatalf("not expired yet, got %q", out.String())
	}
	run([]string{"expired", "-within", "7", soon}, &out, &bytes.Buffer{}, now)
	if !strings.Contains(out.String(), soon) {
		t.Fatalf("should be flagged as expiring within 7 days")
	}
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
