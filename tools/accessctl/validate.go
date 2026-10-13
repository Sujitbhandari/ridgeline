package main

import (
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
)

var (
	nameRE   = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)
	ticketRE = regexp.MustCompile(`^[A-Z][A-Z0-9]+-\d+$`)
	raeRE    = regexp.MustCompile(`^RAE-\d{4}-\d{3}$`)
	emailRE  = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)
)

// PII in a non-production environment is only allowed under an approved
// risk exception, and only briefly: work in a walled-off scope, then delete.
const piiNonProdMaxDays = 14

// Plan is everything a reviewer needs to approve or reject a request,
// computed from the request + catalog so nobody has to work it out by hand.
type Plan struct {
	Request   *AccessRequest
	Workload  Workload
	Env       Environment
	Expires   time.Time
	Grants    []ResolvedGrant
	Approvers []string
	Warnings  []string
}

type ResolvedGrant struct {
	Resource Resource
	Actions  []string
}

type ValidationError struct{ Problems []string }

func (v *ValidationError) Error() string {
	return fmt.Sprintf("%d problem(s):\n  - %s", len(v.Problems), strings.Join(v.Problems, "\n  - "))
}

func Validate(r *AccessRequest, c *Catalog, now time.Time) (*Plan, error) {
	var p []string
	bad := func(format string, a ...any) { p = append(p, fmt.Sprintf(format, a...)) }
	s := r.Spec
	plan := &Plan{Request: r}

	if r.APIVersion != "ridgeline.dev/v1alpha1" || r.Kind != "AccessRequest" {
		bad("apiVersion/kind must be ridgeline.dev/v1alpha1 AccessRequest")
	}
	if !nameRE.MatchString(r.Metadata.Name) {
		bad("metadata.name %q must be a DNS-1123 label", r.Metadata.Name)
	}
	if !emailRE.MatchString(s.Requester) {
		bad("spec.requester must be an email address")
	}
	if !ticketRE.MatchString(s.Ticket) {
		bad("spec.ticket %q must look like PLAT-123 so the audit trail links back to a ticket", s.Ticket)
	}
	if len(strings.TrimSpace(s.Justification)) < 20 {
		bad("spec.justification must explain the need in at least 20 characters")
	}

	env, ok := c.Environments[s.Environment]
	if !ok {
		bad("unknown environment %q", s.Environment)
	}
	plan.Env = env

	wl, ok := c.workload(s.Subject)
	if !ok {
		bad("subject %q is not a registered workload (namespace/serviceaccount)", s.Subject)
	}
	plan.Workload = wl

	exp, err := time.Parse("2006-01-02", s.Expires)
	switch {
	case err != nil:
		bad("spec.expires must be a date (YYYY-MM-DD); standing access is not allowed")
	case !exp.After(now):
		bad("spec.expires %s is in the past", s.Expires)
	case env.MaxDays > 0 && exp.Sub(now) > time.Duration(env.MaxDays)*24*time.Hour:
		bad("spec.expires is more than %d days out, the maximum for %s", env.MaxDays, s.Environment)
	}
	plan.Expires = exp

	if len(s.Grants) == 0 {
		bad("spec.grants is empty")
	}
	seen := map[string]bool{}
	hasPII := false
	approvers := map[string]bool{"@ridgeline/platform": true}
	for i, g := range s.Grants {
		res, ok := c.resource(g.Resource)
		if !ok {
			bad("grants[%d]: unknown resource %q", i, g.Resource)
			continue
		}
		if seen[res.ID] {
			bad("grants[%d]: %s is listed twice", i, res.ID)
		}
		seen[res.ID] = true
		if res.Owner != wl.Team {
			if t, ok := c.Teams[res.Owner]; ok {
				approvers[t.Reviewers] = true
			}
		}
		if res.Classification == "pii" {
			hasPII = true
		}

		switch res.Kind {
		case "aws":
			if len(g.Actions) == 0 {
				bad("grants[%d]: %s needs an explicit actions list", i, res.ID)
			}
			for _, a := range g.Actions {
				if strings.Contains(a, "*") {
					bad("grants[%d]: wildcard action %q is never allowed", i, a)
				} else if !slices.Contains(res.AllowedActions, a) {
					bad("grants[%d]: action %q is not grantable on %s (allowed: %s)",
						i, a, res.ID, strings.Join(res.AllowedActions, ", "))
				}
			}
		case "service", "external":
			if len(g.Actions) > 0 {
				bad("grants[%d]: %s is a network grant and takes no actions", i, res.ID)
			}
			if res.Kind == "service" && res.Namespace == wl.Namespace && res.App == wl.Name {
				bad("grants[%d]: a workload does not need a grant to reach itself", i)
			}
		default:
			bad("grants[%d]: catalog resource %s has unsupported kind %q", i, res.ID, res.Kind)
		}
		acts := slices.Clone(g.Actions)
		sort.Strings(acts)
		plan.Grants = append(plan.Grants, ResolvedGrant{Resource: res, Actions: acts})
	}

	if hasPII {
		approvers["@ridgeline/security"] = true
		if !env.Production {
			if !raeRE.MatchString(s.RiskException) {
				bad("PII outside production requires an approved risk exception (spec.riskException: RAE-YYYY-NNN)")
			}
			if err == nil && exp.Sub(now) > piiNonProdMaxDays*24*time.Hour {
				bad("PII access outside production is limited to %d days", piiNonProdMaxDays)
			}
		}
		plan.Warnings = append(plan.Warnings, "Grants access to PII-classified data; security review is required.")
	}
	if env.Production {
		plan.Warnings = append(plan.Warnings,
			fmt.Sprintf("Production change: %d approvals required.", max(env.ApprovalsRequired, 1)))
	}

	for a := range approvers {
		plan.Approvers = append(plan.Approvers, a)
	}
	sort.Strings(plan.Approvers)

	if len(p) > 0 {
		return plan, &ValidationError{Problems: p}
	}
	return plan, nil
}
