package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/goccy/go-yaml"
)

// Every rendered object carries these annotations/tags, so anyone looking at
// a live IAM policy or NetworkPolicy can trace it to who asked, why, which
// ticket, and when it stops existing.
func auditMeta(p *Plan) map[string]string {
	sum := sha256.Sum256(p.Request.Raw)
	return map[string]string{
		"ridgeline.dev/request":      p.Request.Metadata.Name,
		"ridgeline.dev/ticket":       p.Request.Spec.Ticket,
		"ridgeline.dev/requester":    p.Request.Spec.Requester,
		"ridgeline.dev/expires":      p.Request.Spec.Expires,
		"ridgeline.dev/request-hash": hex.EncodeToString(sum[:8]),
	}
}

// IRSA role naming is a platform convention shared with infra/terraform.
func roleName(env string, w Workload) string {
	return fmt.Sprintf("%s-%s-%s", env, w.Namespace, w.Name)
}

type iamStatement struct {
	Sid      string   `json:"Sid"`
	Effect   string   `json:"Effect"`
	Action   []string `json:"Action"`
	Resource []string `json:"Resource"`
}

type iamPolicy struct {
	Version   string         `json:"Version"`
	Statement []iamStatement `json:"Statement"`
}

// RenderIAM returns Terraform JSON (consumed by infra/terraform/access) or nil
// when the request has no AWS grants.
func RenderIAM(p *Plan) ([]byte, error) {
	env := p.Request.Spec.Environment
	pol := iamPolicy{Version: "2012-10-17"}
	for _, g := range p.Grants {
		if g.Resource.Kind != "aws" {
			continue
		}
		arns := make([]string, 0, len(g.Resource.ARN))
		for _, a := range g.Resource.ARN {
			arns = append(arns, expandARN(a, env, p.Env))
		}
		pol.Statement = append(pol.Statement, iamStatement{
			Sid:      sid(g.Resource.ID),
			Effect:   "Allow",
			Action:   g.Actions,
			Resource: arns,
		})
	}
	if len(pol.Statement) == 0 {
		return nil, nil
	}
	doc, err := json.Marshal(pol)
	if err != nil {
		return nil, err
	}
	id := strings.ReplaceAll(p.Request.Metadata.Name, "-", "_")
	tags := map[string]string{}
	for k, v := range auditMeta(p) {
		tags[strings.TrimPrefix(k, "ridgeline.dev/")] = v
	}
	tf := map[string]any{
		"resource": map[string]any{
			"aws_iam_policy": map[string]any{
				id: map[string]any{
					"name":        fmt.Sprintf("access-%s-%s", env, p.Request.Metadata.Name),
					"description": fmt.Sprintf("%s: %s", p.Request.Spec.Ticket, firstLine(p.Request.Spec.Justification)),
					"policy":      string(doc),
					"tags":        tags,
				},
			},
			"aws_iam_role_policy_attachment": map[string]any{
				id: map[string]any{
					"role":       roleName(env, p.Workload),
					"policy_arn": fmt.Sprintf("${aws_iam_policy.%s.arn}", id),
				},
			},
		},
	}
	return json.MarshalIndent(tf, "", "  ")
}

func sid(id string) string {
	var b strings.Builder
	for _, part := range strings.FieldsFunc(id, func(r rune) bool { return r == '/' || r == '-' || r == '_' }) {
		b.WriteString(strings.ToUpper(part[:1]) + part[1:])
	}
	return b.String()
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

type obj = map[string]any

// RenderNetwork returns Kubernetes NetworkPolicies opening exactly the paths
// requested on top of the platform's default-deny baseline.
func RenderNetwork(p *Plan) ([]obj, error) {
	var out []obj
	w := p.Workload
	meta := auditMeta(p)
	name := "access-" + p.Request.Metadata.Name
	from := obj{"app.kubernetes.io/name": w.Name}

	for _, g := range p.Grants {
		r := g.Resource
		switch r.Kind {
		case "service":
			port := []obj{{"protocol": "TCP", "port": r.Port}}
			// Include the resource id. Two service grants in one request would
			// otherwise render two policies with the same name, and the second
			// apply would drop the first.
			suffix := sanitize(r.ID)
			out = append(out,
				networkPolicy(name+"-"+suffix+"-egress", w.Namespace, meta, from, "Egress", obj{
					"egress": []obj{{
						"to": []obj{{
							"namespaceSelector": obj{"matchLabels": obj{"kubernetes.io/metadata.name": r.Namespace}},
							"podSelector":       obj{"matchLabels": obj{"app.kubernetes.io/name": r.App}},
						}},
						"ports": port,
					}},
				}),
				networkPolicy(name+"-"+suffix+"-ingress", r.Namespace, meta, obj{"app.kubernetes.io/name": r.App}, "Ingress", obj{
					"ingress": []obj{{
						"from": []obj{{
							"namespaceSelector": obj{"matchLabels": obj{"kubernetes.io/metadata.name": w.Namespace}},
							"podSelector":       obj{"matchLabels": from},
						}},
						"ports": port,
					}},
				}),
			)
		case "external":
			out = append(out, networkPolicy(name+"-"+sanitize(r.ID), w.Namespace, meta, from, "Egress", obj{
				"egress": []obj{{
					"to":    []obj{{"ipBlock": obj{"cidr": r.CIDR}}},
					"ports": []obj{{"protocol": "TCP", "port": r.Port}},
				}},
			}))
		}
	}
	return out, nil
}

func networkPolicy(name, ns string, ann map[string]string, sel obj, typ string, rules obj) obj {
	spec := obj{"podSelector": obj{"matchLabels": sel}, "policyTypes": []string{typ}}
	for k, v := range rules {
		spec[k] = v
	}
	return obj{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata": obj{
			"name":        name,
			"namespace":   ns,
			"labels":      obj{"app.kubernetes.io/managed-by": "accessctl"},
			"annotations": ann,
		},
		"spec": spec,
	}
}

func sanitize(s string) string {
	return strings.Trim(strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			return r
		}
		return '-'
	}, strings.ToLower(s)), "-")
}

// WriteRendered writes all outputs for one plan under outDir/<env>/.
func WriteRendered(p *Plan, outDir string) ([]string, error) {
	env := p.Request.Spec.Environment
	base := filepath.Join(outDir, env)
	var written []string

	iam, err := RenderIAM(p)
	if err != nil {
		return nil, err
	}
	if iam != nil {
		path := filepath.Join(base, "iam", p.Request.Metadata.Name+".tf.json")
		if err := writeFile(path, append(iam, '\n')); err != nil {
			return nil, err
		}
		written = append(written, path)
	}

	nps, err := RenderNetwork(p)
	if err != nil {
		return nil, err
	}
	if len(nps) > 0 {
		var docs []string
		for _, np := range nps {
			b, err := yaml.Marshal(np)
			if err != nil {
				return nil, err
			}
			docs = append(docs, string(b))
		}
		path := filepath.Join(base, "network", p.Request.Metadata.Name+".yaml")
		header := "# Generated by accessctl from " + p.Request.Path + ". Do not edit by hand.\n"
		if err := writeFile(path, []byte(header+strings.Join(docs, "---\n"))); err != nil {
			return nil, err
		}
		written = append(written, path)
	}
	return written, nil
}

func writeFile(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}
