package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/goccy/go-yaml"
)

// Catalog is the platform team's source of truth: which environments exist,
// which workloads can ask for access, and which resources can be granted
// (with the exact actions allowed on each). Developers never write IAM JSON;
// they pick from this menu.
type Catalog struct {
	Environments map[string]Environment `yaml:"environments"`
	Teams        map[string]Team        `yaml:"teams"`
	Workloads    []Workload             `yaml:"workloads"`
	Resources    []Resource             `yaml:"resources"`
}

type Environment struct {
	AccountID         string `yaml:"account_id"`
	Region            string `yaml:"region"`
	MaxDays           int    `yaml:"max_days"`
	ApprovalsRequired int    `yaml:"approvals_required"`
	Production        bool   `yaml:"production"`
}

type Team struct {
	Reviewers string `yaml:"reviewers"` // GitHub team handle, e.g. @ridgeline/risk
}

type Workload struct {
	Namespace string `yaml:"namespace"`
	Name      string `yaml:"name"`
	Team      string `yaml:"team"`
}

func (w Workload) ID() string { return w.Namespace + "/" + w.Name }

// Resource kinds:
//
//	aws      -> rendered to an IAM policy attached to the workload's IRSA role
//	service  -> rendered to Kubernetes NetworkPolicies (egress + ingress)
//	external -> rendered to an egress NetworkPolicy to a CIDR
type Resource struct {
	ID             string   `yaml:"id"`
	Kind           string   `yaml:"kind"`
	Owner          string   `yaml:"owner"`
	Classification string   `yaml:"classification"` // internal | confidential | pii
	ARN            []string `yaml:"arn"`
	AllowedActions []string `yaml:"allowed_actions"`
	Namespace      string   `yaml:"namespace"`
	App            string   `yaml:"app"`
	Port           int      `yaml:"port"`
	CIDR           string   `yaml:"cidr"`
}

type AccessRequest struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
	Metadata   struct {
		Name string `yaml:"name"`
	} `yaml:"metadata"`
	Spec RequestSpec `yaml:"spec"`

	Path string `yaml:"-"`
	Raw  []byte `yaml:"-"`
}

type RequestSpec struct {
	Requester     string  `yaml:"requester"`
	Ticket        string  `yaml:"ticket"`
	Environment   string  `yaml:"environment"`
	Subject       string  `yaml:"subject"`
	Expires       string  `yaml:"expires"`
	Justification string  `yaml:"justification"`
	RiskException string  `yaml:"riskException"`
	Grants        []Grant `yaml:"grants"`
}

type Grant struct {
	Resource string   `yaml:"resource"`
	Actions  []string `yaml:"actions"`
}

func loadCatalog(path string) (*Catalog, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Catalog
	if err := yaml.UnmarshalWithOptions(b, &c, yaml.Strict()); err != nil {
		return nil, fmt.Errorf("catalog %s: %w", path, err)
	}
	return &c, nil
}

func loadRequest(path string) (*AccessRequest, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r AccessRequest
	// Strict: an unknown field is a typo, and a typo in an access request
	// should fail loudly rather than be silently ignored.
	if err := yaml.UnmarshalWithOptions(b, &r, yaml.Strict()); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	r.Path, r.Raw = path, b
	return &r, nil
}

func (c *Catalog) workload(id string) (Workload, bool) {
	for _, w := range c.Workloads {
		if w.ID() == id {
			return w, true
		}
	}
	return Workload{}, false
}

func (c *Catalog) resource(id string) (Resource, bool) {
	for _, r := range c.Resources {
		if r.ID == id {
			return r, true
		}
	}
	return Resource{}, false
}

func expandARN(tmpl string, env string, e Environment) string {
	return strings.NewReplacer("{env}", env, "{account}", e.AccountID, "{region}", e.Region).Replace(tmpl)
}
