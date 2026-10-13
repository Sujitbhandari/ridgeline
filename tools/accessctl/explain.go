package main

import (
	"fmt"
	"strings"
	"time"
)

// Explain renders a plan as Markdown for a PR comment, so a reviewer sees
// "who gets what, where, until when, and who must approve" without reading YAML.
func Explain(p *Plan, verr error, now time.Time) string {
	var b strings.Builder
	r := p.Request
	status := "✅ Valid"
	if verr != nil {
		status = "❌ Needs changes"
	}
	fmt.Fprintf(&b, "### Access request `%s` — %s\n\n", r.Metadata.Name, status)
	fmt.Fprintf(&b, "| | |\n|---|---|\n")
	fmt.Fprintf(&b, "| Workload | `%s` (team %s) |\n", r.Spec.Subject, orDash(p.Workload.Team))
	fmt.Fprintf(&b, "| Environment | %s |\n", r.Spec.Environment)
	fmt.Fprintf(&b, "| Ticket | %s |\n", r.Spec.Ticket)
	fmt.Fprintf(&b, "| Requested by | %s |\n", r.Spec.Requester)
	if !p.Expires.IsZero() {
		days := int(p.Expires.Sub(now).Hours()/24 + 0.5)
		fmt.Fprintf(&b, "| Expires | %s (%d days; removed automatically) |\n", r.Spec.Expires, days)
	}
	if r.Spec.RiskException != "" {
		fmt.Fprintf(&b, "| Risk exception | %s |\n", r.Spec.RiskException)
	}

	b.WriteString("\n**Grants**\n\n")
	for _, g := range p.Grants {
		switch g.Resource.Kind {
		case "aws":
			fmt.Fprintf(&b, "- `%s` (%s): %s\n", g.Resource.ID, g.Resource.Classification, "`"+strings.Join(g.Actions, "`, `")+"`")
		case "service":
			fmt.Fprintf(&b, "- Network: `%s` → `%s/%s:%d`\n", r.Spec.Subject, g.Resource.Namespace, g.Resource.App, g.Resource.Port)
		case "external":
			fmt.Fprintf(&b, "- Egress: `%s` → `%s` (%s:%d)\n", r.Spec.Subject, g.Resource.ID, g.Resource.CIDR, g.Resource.Port)
		}
	}

	if len(p.Approvers) > 0 {
		b.WriteString("\n**Required approvals:** " + strings.Join(p.Approvers, ", ") + "\n")
	}
	for _, w := range p.Warnings {
		b.WriteString("\n> ⚠️ " + w + "\n")
	}
	if ve, ok := verr.(*ValidationError); ok {
		b.WriteString("\n**Problems**\n\n")
		for _, pr := range ve.Problems {
			b.WriteString("- " + pr + "\n")
		}
	}
	return b.String()
}

func orDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}
