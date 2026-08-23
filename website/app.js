function docsApp() {
  const sections = [
    { id: 'projects', category: 'Projects', menu: 'Projects', label: 'Projects', title: 'Projects',
      desc: 'List indexed projects (branch, nodes, edges, size, full root path). Enter opens per-project actions.', tags: ['list_projects'],
      commands: [{ cmd: 'r', note: 'refresh' }, { cmd: 'n', note: 'scan' }, { cmd: 'd', note: 'delete' }, { cmd: 'Enter', note: 'project actions' }] },
    { id: 'project-actions', category: 'Projects', menu: 'Project actions', label: 'Project actions', title: 'Per-project actions',
      desc: 'Run on the selected project.', tags: ['index_status','get_architecture','check_index_coverage','detect_changes','delete_project','index_repository'],
      commands: [
        { cmd: 'Index status', note: 'nodes/edges/parse gaps' },
        { cmd: 'Architecture overview', note: 'clusters, dependencies' },
        { cmd: 'Index coverage', note: 'missed ranges' },
        { cmd: 'Detect changes', note: 'blame/impact from git diff' },
        { cmd: 'Re-scan / Delete', note: '' },
      ]},
    { id: 'scan', category: 'Scan', menu: 'Scan / Index', label: 'Scan', title: 'Scan / Index a repository',
      desc: 'Add a repo to the knowledge graph.', tags: ['index_repository','cross-repo-intelligence'],
      snippet: 'repo path: /path/to/repo\nmode: moderate | full | fast | cross-repo\npersist artifact: no | yes  → .codebase-memory/graph.db.zst' },
    { id: 'server', category: 'Server', menu: 'Graph server', label: 'Graph server', title: 'Graph server (UI)',
      desc: 'Start/stop the 3D graph UI and manage its port.', tags: ['ui_enabled','ui_port'],
      commands: [
        { cmd: 'Start / Stop', note: 'config set ui_enabled' },
        { cmd: 'Set port', note: 'config set ui_port' },
        { cmd: 'Open in browser', note: 'http://localhost:9749' },
      ]},
    { id: 'processes', category: 'Monitor', menu: 'Processes', label: 'Processes', title: 'Processes & resources',
      desc: 'Live monitor of every codebase-memory-mcp process (CPU, mem, RSS, uptime) + artifact sizes in the cache dir. Auto-refreshing.', tags: ['ps','du'],
      commands: [{ cmd: 'r', note: 'refresh' }, { cmd: '↑/↓', note: 'scroll' }] },
    { id: 'configuration', category: 'Config', menu: 'Configuration', label: 'Configuration', title: 'Configuration editor',
      desc: 'View and edit persisted settings; SAVE ALL applies everything.', tags: ['config list','config set'],
      commands: [{ cmd: 'SAVE ALL', note: 'apply' }, { cmd: 'REFRESH', note: 'reload' }] },
    { id: 'queries', category: 'Query', menu: 'Graph queries', label: 'Graph queries', title: 'Graph queries',
      desc: 'All MCP query tools via forms — long jobs run in background with spinner.', tags: ['search_graph','search_code','get_code_snippet','trace_path','query_graph','get_graph_schema','ingest_traces'],
      commands: [
        { cmd: 'Search graph', note: 'BM25 / name / semantic' },
        { cmd: 'Search code', note: 'grep + graph enrich' },
        { cmd: 'Get code snippet', note: 'qualified_name' },
        { cmd: 'Trace path', note: 'callers/callees' },
        { cmd: 'Cypher query', note: 'raw graph query' },
      ]},
    { id: 'adr', category: 'Docs', menu: 'ADR', label: 'ADR', title: 'ADR management',
      desc: 'Get / list sections / update architecture decision records.', tags: ['manage_adr'],
      commands: [{ cmd: 'get', note: 'fetch ADR' }, { cmd: 'sections', note: 'list headings' }, { cmd: 'update', note: 'replace from file' }] },
    { id: 'maintenance', category: 'Maintenance', menu: 'Maintenance', label: 'Maintenance', title: 'Maintenance',
      desc: 'Diagnostics and lifecycle.', tags: ['--version','--help','update','uninstall'],
      commands: [
        { cmd: 'Version / CLI help', note: '' },
        { cmd: 'Update', note: 'show command' },
        { cmd: 'Cache & diagnostics', note: 'artifacts, logs' },
      ]},
  ];

  const navSections = sections.map(s => ({ id: s.id, label: s.label }));

  return {
    q: '',
    mobileSearch: false,
    isMac: navigator.platform.toUpperCase().indexOf('MAC') >= 0,
    latestRelease: null,
    staticVersion: (document.querySelector('meta[name="cbmman-version"]') || {}).content || '',
    sections,
    navSections,
    get filteredCount() {
      if (!this.q) return sections.length;
      const qq = this.q.toLowerCase();
      return sections.filter(s => this.hit(s, qq)).length;
    },
    async loadLatestRelease() {
      try {
        const res = await fetch('https://api.github.com/repos/handyutils/cbmman/releases/latest');
        if (res.ok) {
          this.latestRelease = await res.json();
        }
      } catch (e) {
        console.warn('Failed to load latest release', e);
      }
    },
    releaseUrl(asset) {
      if (!this.latestRelease) return '#';
      return asset ? asset.browser_download_url : this.latestRelease.html_url;
    },
    releaseVersion() {
      if (this.latestRelease) {
        return this.latestRelease.name || this.latestRelease.tag_name || '';
      }
      return this.staticVersion;
    },
    releaseNotes() {
      if (!this.latestRelease) return '';
      return this.latestRelease.body || '';
    },
    hit(s, qq) {
      const hay = [s.title, s.desc, s.category, s.menu, ...(s.tags||[]), ...(s.commands||[]).map(c=>c.cmd+' '+c.note), s.snippet||''].join(' ').toLowerCase();
      return hay.includes(qq);
    },
    matches(s) {
      if (!this.q) return true;
      return this.hit(s, this.q.toLowerCase());
    },
    matchesId(id) {
      if (!this.q) return true;
      const qq = this.q.toLowerCase();
      return id.includes(qq) || 'quickstart install usage configuration environment cli'.includes(qq) && ['quickstart','install','usage','config','env','cli'].includes(id);
    },
    init() {
      this.loadLatestRelease();
      document.addEventListener('keydown', (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); document.querySelector('input[x-model="q"]')?.focus(); }
        if (e.key === '/' && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) { e.preventDefault(); document.querySelector('input[x-model="q"]')?.focus(); }
      });
    },
    copy(btn) {
      const code = btn.nextElementSibling?.innerText || '';
      this.copyText(code);
    },
    copyText(t) {
      navigator.clipboard.writeText(t).catch(()=>{});
      const n = document.createElement('div');
      n.textContent = 'Copied';
      n.className = 'fixed bottom-4 left-1/2 -translate-x-1/2 bg-ink text-white text-xs px-3 py-1.5 rounded-full';
      document.body.appendChild(n);
      setTimeout(()=>n.remove(), 1200);
    }
  };
}
