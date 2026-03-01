// coverage generates an HTML report showing which Terraform modules have unit tests.
// Usage: go run ./cmd/coverage/main.go <project-root>
package main

import (
	"bufio"
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

type Module struct {
	RelPath  string // e.g. "atoms/aws/network/vpc"
	Layer    string // "Atom", "Molecule", "Organism"
	Name     string // e.g. "aws/network/vpc"
	Validate bool
	Plan     bool
}

func (m Module) CoverageClass() string {
	switch {
	case m.Validate && m.Plan:
		return "full"
	case m.Validate || m.Plan:
		return "partial"
	default:
		return "none"
	}
}

type testCoverage struct {
	Validate bool
	Plan     bool
}

func main() {
	root := "."
	if len(os.Args) > 1 {
		root = os.Args[1]
	}
	root, _ = filepath.Abs(root)

	modules, err := findModules(root)
	if err != nil {
		fatalf("finding modules: %v", err)
	}

	fixtureSources, err := parseFixtureSources(root)
	if err != nil {
		fatalf("parsing fixtures: %v", err)
	}

	testTypes, err := parseTestFiles(root)
	if err != nil {
		fatalf("parsing test files: %v", err)
	}

	for i := range modules {
		for fixtureName, srcPaths := range fixtureSources {
			for _, srcPath := range srcPaths {
				if srcPath == modules[i].RelPath {
					tc := testTypes[fixtureName]
					modules[i].Validate = modules[i].Validate || tc.Validate
					modules[i].Plan = modules[i].Plan || tc.Plan
				}
			}
		}
	}

	sort.Slice(modules, func(i, j int) bool {
		if modules[i].Layer != modules[j].Layer {
			return modules[i].Layer < modules[j].Layer
		}
		return modules[i].Name < modules[j].Name
	})

	outputPath := filepath.Join(root, "coverage.html")
	if err := renderHTML(modules, outputPath); err != nil {
		fatalf("generating HTML: %v", err)
	}

	fmt.Printf("Report written to: %s\n", outputPath)
	printSummary(modules)
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", args...)
	os.Exit(1)
}

// findModules returns all directories under atoms/, molecules/, organisms/ that
// directly contain .tf files.
func findModules(root string) ([]Module, error) {
	layerDirs := []struct {
		dir   string
		layer string
	}{
		{"atoms", "Atom"},
		{"molecules", "Molecule"},
		{"organisms", "Organism"},
	}

	var modules []Module
	for _, ld := range layerDirs {
		layerPath := filepath.Join(root, ld.dir)
		if _, err := os.Stat(layerPath); os.IsNotExist(err) {
			continue
		}
		err := filepath.Walk(layerPath, func(path string, info os.FileInfo, err error) error {
			if err != nil || !info.IsDir() {
				return err
			}
			entries, err := os.ReadDir(path)
			if err != nil {
				return err
			}
			for _, e := range entries {
				if !e.IsDir() && strings.HasSuffix(e.Name(), ".tf") {
					relPath, _ := filepath.Rel(root, path)
					name, _ := filepath.Rel(filepath.Join(root, ld.dir), path)
					modules = append(modules, Module{
						RelPath: filepath.ToSlash(relPath),
						Layer:   ld.layer,
						Name:    filepath.ToSlash(name),
					})
					return nil
				}
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	return modules, nil
}

// parseFixtureSources returns map[fixtureName][]moduleRelPath extracted from
// source = "..." lines in each fixture's main.tf.
func parseFixtureSources(root string) (map[string][]string, error) {
	fixturesDir := filepath.Join(root, "tests", "fixtures")
	result := make(map[string][]string)

	entries, err := os.ReadDir(fixturesDir)
	if err != nil {
		if os.IsNotExist(err) {
			return result, nil
		}
		return nil, err
	}

	sourceRe := regexp.MustCompile(`source\s*=\s*"([^"]+)"`)

	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		fixtureName := e.Name()
		fixtureDir := filepath.Join(fixturesDir, fixtureName)
		mainTf := filepath.Join(fixtureDir, "main.tf")

		f, err := os.Open(mainTf)
		if err != nil {
			continue
		}

		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			m := sourceRe.FindStringSubmatch(scanner.Text())
			if m == nil {
				continue
			}
			abs := filepath.Clean(filepath.Join(fixtureDir, m[1]))
			rel, err := filepath.Rel(root, abs)
			if err != nil {
				continue
			}
			result[fixtureName] = append(result[fixtureName], filepath.ToSlash(rel))
		}
		f.Close()
	}
	return result, nil
}

// parseTestFiles returns map[fixtureName]testCoverage by scanning test functions
// for helpers.FixturePath calls and terraform.InitAndValidate / InitAndPlan calls.
func parseTestFiles(root string) (map[string]testCoverage, error) {
	testDir := filepath.Join(root, "tests", "unit")
	result := make(map[string]testCoverage)

	fixtureRe := regexp.MustCompile(`helpers\.FixturePath\(t,\s*"([^"]+)"`)

	entries, err := os.ReadDir(testDir)
	if err != nil {
		return nil, err
	}

	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), "_test.go") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(testDir, e.Name()))
		if err != nil {
			return nil, err
		}

		var currentFixture string
		var hasValidate, hasPlan bool

		flush := func() {
			if currentFixture == "" {
				return
			}
			tc := result[currentFixture]
			tc.Validate = tc.Validate || hasValidate
			tc.Plan = tc.Plan || hasPlan
			result[currentFixture] = tc
		}

		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "func Test") {
				flush()
				currentFixture, hasValidate, hasPlan = "", false, false
			}
			if m := fixtureRe.FindStringSubmatch(line); m != nil {
				currentFixture = m[1]
			}
			if strings.Contains(line, "terraform.Validate(") || strings.Contains(line, "InitAndValidate") {
				hasValidate = true
			}
			if strings.Contains(line, "InitAndPlan") {
				hasPlan = true
			}
		}
		flush()
	}
	return result, nil
}

func printSummary(modules []Module) {
	total := len(modules)
	var covered, validate, plan int
	for _, m := range modules {
		if m.Validate || m.Plan {
			covered++
		}
		if m.Validate {
			validate++
		}
		if m.Plan {
			plan++
		}
	}
	pct := 0
	if total > 0 {
		pct = covered * 100 / total
	}
	fmt.Printf("\nSummary\n")
	fmt.Printf("  Total modules : %d\n", total)
	fmt.Printf("  With tests    : %d / %d (%d%%)\n", covered, total, pct)
	fmt.Printf("  Validate      : %d\n", validate)
	fmt.Printf("  Plan          : %d\n", plan)
	fmt.Printf("  No tests      : %d\n", total-covered)
}

// ---- HTML rendering --------------------------------------------------------

type templateModule struct {
	Name       string
	Layer      string
	LayerClass string
	Validate   bool
	Plan       bool
}

func (m templateModule) CoverageClass() string {
	switch {
	case m.Validate && m.Plan:
		return "full"
	case m.Validate || m.Plan:
		return "partial"
	default:
		return "none"
	}
}

func (m templateModule) Covered() bool { return m.Validate || m.Plan }

type templateData struct {
	Total         int
	Covered       int
	CoveredPct    int
	ValidateCount int
	PlanCount     int
	Uncovered     int
	Modules       []templateModule
	GeneratedAt   string
}

func renderHTML(modules []Module, outputPath string) error {
	tmpl, err := template.New("coverage").Parse(htmlTemplate)
	if err != nil {
		return err
	}

	var covered, validate, plan int
	for _, m := range modules {
		if m.Validate || m.Plan {
			covered++
		}
		if m.Validate {
			validate++
		}
		if m.Plan {
			plan++
		}
	}

	covPct := 0
	if len(modules) > 0 {
		covPct = covered * 100 / len(modules)
	}

	var tmplModules []templateModule
	for _, m := range modules {
		tmplModules = append(tmplModules, templateModule{
			Name:       m.Name,
			Layer:      m.Layer,
			LayerClass: strings.ToLower(m.Layer),
			Validate:   m.Validate,
			Plan:       m.Plan,
		})
	}

	data := templateData{
		Total:         len(modules),
		Covered:       covered,
		CoveredPct:    covPct,
		ValidateCount: validate,
		PlanCount:     plan,
		Uncovered:     len(modules) - covered,
		Modules:       tmplModules,
		GeneratedAt:   time.Now().Format("2006-01-02 15:04:05"),
	}

	f, err := os.Create(outputPath)
	if err != nil {
		return err
	}
	defer f.Close()
	return tmpl.Execute(f, data)
}

const htmlTemplate = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Terraform Module Coverage</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 0; padding: 24px; background: #f0f2f5; color: #333; }
  h1 { margin: 0 0 24px; font-size: 1.6em; color: #1a1a2e; }

  .summary { display: flex; gap: 16px; margin-bottom: 28px; flex-wrap: wrap; }
  .card { background: white; border-radius: 10px; padding: 18px 24px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); min-width: 130px; }
  .card .val { font-size: 2.2em; font-weight: 700; line-height: 1; }
  .card .lbl { color: #777; font-size: 0.82em; margin-top: 6px; text-transform: uppercase; letter-spacing: 0.04em; }
  .bar-wrap { background: #e8e8e8; border-radius: 6px; height: 6px; margin-top: 10px; }
  .bar-fill { background: linear-gradient(90deg, #43a047, #66bb6a); border-radius: 6px; height: 6px; transition: width 0.6s ease; }

  .controls { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 16px; align-items: center; }
  .controls span { font-size: 0.85em; color: #888; margin-right: 4px; }
  .btn { padding: 6px 14px; border: 1px solid #d0d0d0; border-radius: 6px; cursor: pointer; background: white; font-size: 0.85em; transition: all 0.15s; }
  .btn:hover { border-color: #aaa; }
  .btn.active { background: #1a1a2e; color: white; border-color: #1a1a2e; }

  table { width: 100%; border-collapse: collapse; background: white; border-radius: 10px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); overflow: hidden; }
  th { background: #1a1a2e; color: #e8e8e8; padding: 12px 16px; text-align: left; font-size: 0.82em; font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase; }
  td { padding: 10px 16px; border-bottom: 1px solid #f0f0f0; font-size: 0.92em; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #fafbff; }

  tr.full td:first-child { border-left: 3px solid #43a047; }
  tr.partial td:first-child { border-left: 3px solid #fb8c00; }
  tr.none td:first-child { border-left: 3px solid #e53935; }

  code { font-size: 0.88em; background: #f5f5f5; padding: 2px 6px; border-radius: 4px; }
  .badge { display: inline-block; padding: 2px 10px; border-radius: 12px; font-size: 0.78em; font-weight: 600; letter-spacing: 0.03em; }
  .badge-atom { background: #e3f2fd; color: #1565c0; }
  .badge-molecule { background: #f3e5f5; color: #6a1b9a; }
  .badge-organism { background: #e8f5e9; color: #2e7d32; }

  .icon-ok  { color: #43a047; font-size: 1.1em; }
  .icon-no  { color: #ccc; font-size: 1.1em; }

  .footer { color: #aaa; font-size: 0.78em; margin-top: 20px; text-align: right; }
</style>
</head>
<body>
<h1>Terraform Module Test Coverage</h1>

<div class="summary">
  <div class="card">
    <div class="val">{{.Total}}</div>
    <div class="lbl">Total Modules</div>
  </div>
  <div class="card">
    <div class="val" style="color:#43a047">{{.Covered}}</div>
    <div class="lbl">With Tests ({{.CoveredPct}}%)</div>
    <div class="bar-wrap"><div class="bar-fill" style="width:{{.CoveredPct}}%"></div></div>
  </div>
  <div class="card">
    <div class="val" style="color:#1565c0">{{.ValidateCount}}</div>
    <div class="lbl">Validate</div>
  </div>
  <div class="card">
    <div class="val" style="color:#6a1b9a">{{.PlanCount}}</div>
    <div class="lbl">Plan</div>
  </div>
  <div class="card">
    <div class="val" style="color:#e53935">{{.Uncovered}}</div>
    <div class="lbl">No Tests</div>
  </div>
</div>

<div class="controls">
  <span>Filter:</span>
  <button class="btn active" onclick="applyFilter(this,'layer','all')">All</button>
  <button class="btn" onclick="applyFilter(this,'layer','Atom')">Atoms</button>
  <button class="btn" onclick="applyFilter(this,'layer','Molecule')">Molecules</button>
  <button class="btn" onclick="applyFilter(this,'layer','Organism')">Organisms</button>
  &nbsp;
  <button class="btn" onclick="applyFilter(this,'covered','yes')">Covered</button>
  <button class="btn" onclick="applyFilter(this,'covered','no')">Uncovered</button>
</div>

<table>
  <thead>
    <tr>
      <th>Module</th>
      <th>Layer</th>
      <th style="text-align:center">Validate</th>
      <th style="text-align:center">Plan</th>
    </tr>
  </thead>
  <tbody>
  {{range .Modules}}
    <tr class="{{.CoverageClass}}" data-layer="{{.Layer}}" data-covered="{{if .Covered}}yes{{else}}no{{end}}">
      <td><code>{{.Name}}</code></td>
      <td><span class="badge badge-{{.LayerClass}}">{{.Layer}}</span></td>
      <td style="text-align:center">{{if .Validate}}<span class="icon-ok">✓</span>{{else}}<span class="icon-no">✗</span>{{end}}</td>
      <td style="text-align:center">{{if .Plan}}<span class="icon-ok">✓</span>{{else}}<span class="icon-no">✗</span>{{end}}</td>
    </tr>
  {{end}}
  </tbody>
</table>

<div class="footer">Generated {{.GeneratedAt}}</div>

<script>
  var activeFilters = { layer: 'all', covered: 'all' };

  function applyFilter(btn, key, val) {
    activeFilters[key] = val;

    // Update button active state per group
    var groups = { layer: ['all','Atom','Molecule','Organism'], covered: ['yes','no'] };
    document.querySelectorAll('.btn').forEach(function(b) {
      var bVal = b.getAttribute('onclick').match(/'([^']+)'\)$/)[1];
      var bKey = b.getAttribute('onclick').match(/'([^']+)',/)[1];
      if (bKey === key) b.classList.toggle('active', bVal === val);
    });

    document.querySelectorAll('tbody tr').forEach(function(row) {
      var layerOk = activeFilters.layer === 'all' || row.dataset.layer === activeFilters.layer;
      var covOk   = activeFilters.covered === 'all' || row.dataset.covered === activeFilters.covered;
      row.style.display = (layerOk && covOk) ? '' : 'none';
    });
  }
</script>
</body>
</html>
`
