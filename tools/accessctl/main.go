// accessctl turns the platform team's most common interrupt — "can service X
// talk to Y / read Z?" — into a self-service pull request.
//
// A developer adds a small YAML file under access-requests/. CI runs
// `accessctl explain` and posts the plan on the PR; CODEOWNERS routes it to
// exactly the teams that must approve; on merge, `accessctl render` produces
// least-privilege IAM (Terraform) and NetworkPolicies (Argo CD). Every grant
// expires, and a nightly job removes expired ones. Git history is the audit trail.
//
//	accessctl validate [-catalog FILE] REQUEST...
//	accessctl explain  [-catalog FILE] REQUEST...
//	accessctl render   [-catalog FILE] [-out DIR] REQUEST...
//	accessctl expired  [-within DAYS] REQUEST...
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"time"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, time.Now().UTC()))
}

func run(args []string, stdout, stderr io.Writer, now time.Time) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: accessctl validate|explain|render|expired [flags] REQUEST...")
		return 2
	}
	cmd := args[0]
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(stderr)
	catalogPath := fs.String("catalog", "access-requests/catalog.yaml", "service and resource catalog")
	outDir := fs.String("out", "access-requests/rendered", "render output directory")
	within := fs.Int("within", 0, "expired: also list requests expiring within N days")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	paths, err := expand(fs.Args())
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}

	if cmd == "expired" {
		return expired(paths, now, *within, stdout, stderr)
	}

	cat, err := loadCatalog(*catalogPath)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}

	failed := false
	for _, path := range paths {
		req, err := loadRequest(path)
		if err != nil {
			fmt.Fprintln(stderr, err)
			failed = true
			continue
		}
		plan, verr := Validate(req, cat, now)
		switch cmd {
		case "validate":
			if verr != nil {
				fmt.Fprintf(stderr, "%s: %v\n", path, verr)
			} else {
				fmt.Fprintf(stdout, "%s: ok\n", path)
			}
		case "explain":
			fmt.Fprintln(stdout, Explain(plan, verr, now))
		case "render":
			if verr != nil {
				fmt.Fprintf(stderr, "%s: refusing to render: %v\n", path, verr)
				break
			}
			files, err := WriteRendered(plan, *outDir)
			if err != nil {
				fmt.Fprintf(stderr, "%s: %v\n", path, err)
				failed = true
			}
			for _, f := range files {
				fmt.Fprintln(stdout, "wrote", f)
			}
		default:
			fmt.Fprintf(stderr, "unknown command %q\n", cmd)
			return 2
		}
		if verr != nil {
			failed = true
		}
	}
	if failed {
		return 1
	}
	return 0
}

func expired(paths []string, now time.Time, within int, stdout, stderr io.Writer) int {
	cutoff := now.Add(time.Duration(within) * 24 * time.Hour)
	for _, path := range paths {
		req, err := loadRequest(path)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 2
		}
		exp, err := time.Parse("2006-01-02", req.Spec.Expires)
		if err != nil || !exp.After(cutoff) {
			fmt.Fprintln(stdout, path)
		}
	}
	return 0
}

// expand accepts files or directories; directories are walked for *.yaml,
// skipping the catalog and rendered output.
func expand(args []string) ([]string, error) {
	var out []string
	for _, a := range args {
		info, err := os.Stat(a)
		if err != nil {
			return nil, err
		}
		if !info.IsDir() {
			out = append(out, a)
			continue
		}
		err = filepath.WalkDir(a, func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() && d.Name() == "rendered" {
				return filepath.SkipDir
			}
			if !d.IsDir() && filepath.Ext(p) == ".yaml" && d.Name() != "catalog.yaml" {
				out = append(out, p)
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	if len(out) == 0 {
		return nil, errors.New("no access request files given")
	}
	sort.Strings(out)
	return out, nil
}
