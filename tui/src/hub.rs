//! Read-only multi-project hub for the user-global Orchestra registry.
//!
//! The hub trusts the registry as the only project-routing authority: it reads the registered
//! roots verbatim and never searches sibling directories. Every per-project datum is a best-effort
//! observation of `.work/` or `.inbox/`; this module neither takes leases nor runs project tools.

use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use orchestra_engine::state::Snapshot;
use serde_json::Value;

use crate::commands;
use crate::inbox;

const REGISTRY_SCHEMA: &str = "orchestra/project-registry@1";

/// One project row in the read-only operator hub.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HubProject {
    pub id: String,
    pub name: String,
    pub root: PathBuf,
    pub work_dir: PathBuf,
    pub available: bool,
    pub lease: String,
    pub cohort: String,
    pub pending_approvals: usize,
    pub escalations: usize,
    pub actionable_messages: usize,
}

impl HubProject {
    pub fn attention_count(&self) -> usize {
        self.pending_approvals + self.escalations + self.actionable_messages
    }
}

/// UI-local state for the registry-backed hub. An unreadable registry is visible as a notice,
/// never silently replaced by a filesystem scan.
#[derive(Debug, Clone, Default)]
pub struct HubState {
    pub projects: Vec<HubProject>,
    pub selected: usize,
    pub notice: Option<String>,
}

impl HubState {
    pub fn reload_default(&mut self) {
        match registry_path() {
            Ok(path) => self.reload_from(&path),
            Err(error) => self.set_error(error),
        }
    }

    pub fn reload_from(&mut self, path: &Path) {
        let selected_id = self.selected_project().map(|project| project.id.clone());
        match load(path) {
            Ok(projects) => {
                self.projects = projects;
                self.notice = None;
                self.selected = selected_id
                    .as_deref()
                    .and_then(|id| self.projects.iter().position(|project| project.id == id))
                    .unwrap_or_else(|| self.selected.min(self.projects.len().saturating_sub(1)));
            }
            Err(error) => self.set_error(error),
        }
    }

    fn set_error(&mut self, error: String) {
        self.projects.clear();
        self.selected = 0;
        self.notice = Some(error);
    }

    pub fn select(&mut self, delta: i16) {
        if self.projects.is_empty() {
            self.selected = 0;
            return;
        }
        let max = self.projects.len().saturating_sub(1) as i32;
        self.selected = (self.selected as i32 + i32::from(delta)).clamp(0, max) as usize;
    }

    pub fn selected_project(&self) -> Option<&HubProject> {
        self.projects.get(self.selected)
    }
}

/// Read and summarize every registry project. A registered-but-missing root stays visible as an
/// unavailable row; malformed registry metadata fails closed instead of trusting a path.
pub fn load(path: &Path) -> Result<Vec<HubProject>, String> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let text = fs::read_to_string(path)
        .map_err(|error| format!("не удалось прочитать registry {}: {error}", path.display()))?;
    let root: Value = serde_json::from_str(&text)
        .map_err(|error| format!("registry содержит нераспознанный JSON: {error}"))?;
    if root.get("schema").and_then(Value::as_str) != Some(REGISTRY_SCHEMA) {
        return Err("registry имеет неподдерживаемую schema".to_string());
    }
    let projects = root
        .get("projects")
        .and_then(Value::as_array)
        .ok_or_else(|| "registry не содержит projects array".to_string())?;

    let mut rows = Vec::with_capacity(projects.len());
    let mut ids = HashSet::with_capacity(projects.len());
    for project in projects {
        let id = project_string(project, "id")?;
        if !is_project_id(&id) {
            return Err(format!("registry project имеет некорректный id: {id}"));
        }
        if !ids.insert(id.clone()) {
            return Err(format!("registry содержит duplicate project id: {id}"));
        }
        let name = project_string(project, "name")?;
        if name.chars().count() > 120 || name.chars().any(char::is_control) {
            return Err(format!("registry project {id} имеет некорректное name"));
        }
        let root = PathBuf::from(project_string(project, "root")?);
        if !root.is_absolute() {
            return Err(format!("registry project {id} имеет не-absolute root"));
        }
        rows.push(summarize_project(id, name, root));
    }
    rows.sort_by(|left, right| {
        left.name
            .cmp(&right.name)
            .then_with(|| left.id.cmp(&right.id))
    });
    Ok(rows)
}

fn registry_path() -> Result<PathBuf, String> {
    if let Some(path) = env::var_os("ORCHESTRA_REGISTRY_PATH") {
        if !path.is_empty() {
            return Ok(PathBuf::from(path));
        }
    }
    let home = env::var_os("USERPROFILE")
        .or_else(|| env::var_os("HOME"))
        .filter(|path| !path.is_empty())
        .ok_or_else(|| "не удалось определить user profile для registry".to_string())?;
    Ok(PathBuf::from(home).join(".orchestra").join("projects.json"))
}

fn project_string(project: &Value, key: &str) -> Result<String, String> {
    project
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| format!("registry project не содержит {key}"))
}

fn is_project_id(value: &str) -> bool {
    value.len() == 25
        && value.starts_with("repo-")
        && value[5..].bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn summarize_project(id: String, name: String, root: PathBuf) -> HubProject {
    let work_dir = root.join(".work");
    if !is_plain_directory(&root) || !is_plain_directory(&work_dir) {
        return HubProject {
            id,
            name,
            root,
            work_dir,
            available: false,
            lease: "недоступен".to_string(),
            cohort: "недоступен".to_string(),
            pending_approvals: 0,
            escalations: 0,
            actionable_messages: 0,
        };
    }

    let snapshot = Snapshot::load(&work_dir);
    let decision_inbox = inbox::load(&work_dir, &commands::now_iso8601());
    HubProject {
        id,
        name,
        root: root.clone(),
        work_dir: work_dir.clone(),
        available: true,
        lease: lease_summary(&work_dir),
        cohort: cohort_summary(&snapshot),
        pending_approvals: decision_inbox.approvals.len(),
        escalations: decision_inbox.escalated.len(),
        actionable_messages: actionable_message_count(&root),
    }
}

fn lease_summary(work_dir: &Path) -> String {
    let lock = work_dir.join("orchestrator.lock");
    if !lock.exists() {
        return "свободна".to_string();
    }
    let lease = lock.join("lease.json");
    let Ok(text) = fs::read_to_string(lease) else {
        return "нечитаемая".to_string();
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return "нечитаемая".to_string();
    };
    let owner = value.get("owner_id").and_then(Value::as_str).unwrap_or("?");
    let role = value.get("role").and_then(Value::as_str).unwrap_or("?");
    format!("занята · {role}/{owner}")
}

fn cohort_summary(snapshot: &Snapshot) -> String {
    let Some(cohort) = snapshot.cohort.as_ref() else {
        return "idle".to_string();
    };
    let batch = cohort.batch_id.as_deref().unwrap_or("?");
    let admission = cohort.admission_literal.as_deref().unwrap_or("?");
    format!("{batch} · {admission}")
}

fn actionable_message_count(root: &Path) -> usize {
    let inbox = root.join(".inbox");
    let dir = inbox.join("messages");
    if !is_plain_directory(&inbox) || !is_plain_directory(&dir) {
        return 0;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return 0;
    };
    entries
        .flatten()
        .filter(|entry| entry.path().extension().and_then(|ext| ext.to_str()) == Some("json"))
        .filter(|entry| is_plain_file(&entry.path()))
        .filter_map(|entry| fs::read_to_string(entry.path()).ok())
        .filter_map(|text| serde_json::from_str::<Value>(&text).ok())
        .filter(|message| {
            matches!(
                message.get("processing_status").and_then(Value::as_str),
                Some("new") | Some("read")
            )
        })
        .count()
}

/// The inbox contract rejects symlinks/reparse points so a cross-project observer cannot be
/// redirected outside one registered root. Keep the same invariant even though this projection is
/// read-only. `symlink_metadata` deliberately checks the link itself rather than following it.
fn is_plain_directory(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .ok()
        .is_some_and(|metadata| metadata.is_dir() && !is_redirected(&metadata))
}

fn is_plain_file(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .ok()
        .is_some_and(|metadata| metadata.is_file() && !is_redirected(&metadata))
}

fn is_redirected(metadata: &fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
    }
    #[cfg(not(windows))]
    {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            let stamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock after epoch")
                .as_nanos();
            let path = env::temp_dir().join(format!("orchestra-tui-hub-{label}-{stamp}"));
            fs::create_dir_all(&path).expect("create temp directory");
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn write(path: impl AsRef<Path>, text: &str) {
        let path = path.as_ref();
        fs::create_dir_all(path.parent().expect("fixture parent")).expect("create fixture parent");
        fs::write(path, text).expect("write fixture");
    }

    #[test]
    fn registry_hub_summarizes_registered_roots_without_scanning() {
        let fixture = TempDir::new("summary");
        let live = fixture.0.join("live");
        fs::create_dir_all(&live).expect("create project root");
        write(
            live.join(".work/Tasks_Queue.md"),
            "### [T-101] Need operator — статус: эскалирована · причина=fixture\n",
        );
        write(
            live.join(".work/cohort_state.md"),
            "# Cohort state — Batch B-1\nПриём: открыт\n",
        );
        write(
            live.join(".work/orchestrator.lock/lease.json"),
            r#"{"owner_id":"owner-1","role":"processor"}"#,
        );
        write(
            live.join(".work/approvals/apr-1.json"),
            r#"{"schema":"orchestra/approval@1","id":"apr-1","decision":"","deadline":"2099-01-01T00:00:00Z"}"#,
        );
        write(
            live.join(".inbox/messages/msg-1.json"),
            r#"{"processing_status":"new"}"#,
        );
        let missing = fixture.0.join("missing");
        let registry = fixture.0.join("projects.json");
        let registry_json = serde_json::json!({
            "schema": REGISTRY_SCHEMA,
            "projects": [
                { "id": "repo-00000000000000000001", "name": "Live", "root": live },
                { "id": "repo-00000000000000000002", "name": "Missing", "root": missing },
            ],
        });
        write(&registry, &registry_json.to_string());

        let rows = load(&registry).expect("load registry hub");
        assert_eq!(rows.len(), 2);
        let live = rows
            .iter()
            .find(|row| row.id == "repo-00000000000000000001")
            .expect("live row");
        assert!(live.available);
        assert_eq!(live.pending_approvals, 1);
        assert_eq!(live.escalations, 1);
        assert_eq!(live.actionable_messages, 1);
        assert!(live.lease.contains("processor/owner-1"));
        assert!(live.cohort.contains("B-1"));
        let missing = rows
            .iter()
            .find(|row| row.id == "repo-00000000000000000002")
            .expect("missing row");
        assert!(!missing.available);
    }

    #[test]
    fn hub_selection_clamps_and_preserves_identity_on_reload() {
        let mut hub = HubState {
            projects: vec![
                HubProject {
                    id: "repo-a".into(),
                    name: "A".into(),
                    root: PathBuf::new(),
                    work_dir: PathBuf::new(),
                    available: true,
                    lease: "free".into(),
                    cohort: "idle".into(),
                    pending_approvals: 0,
                    escalations: 0,
                    actionable_messages: 0,
                },
                HubProject {
                    id: "repo-b".into(),
                    name: "B".into(),
                    root: PathBuf::new(),
                    work_dir: PathBuf::new(),
                    available: true,
                    lease: "free".into(),
                    cohort: "idle".into(),
                    pending_approvals: 0,
                    escalations: 0,
                    actionable_messages: 0,
                },
            ],
            selected: 0,
            notice: None,
        };
        hub.select(1);
        assert_eq!(
            hub.selected_project().map(|project| project.id.as_str()),
            Some("repo-b")
        );
        hub.select(9);
        assert_eq!(hub.selected, 1);
        hub.select(-9);
        assert_eq!(hub.selected, 0);
    }

    #[test]
    fn malformed_registry_fails_closed_instead_of_showing_duplicate_routes() {
        let fixture = TempDir::new("duplicate-id");
        let registry = fixture.0.join("projects.json");
        let root = fixture.0.to_string_lossy();
        write(
            &registry,
            &serde_json::json!({
                "schema": REGISTRY_SCHEMA,
                "projects": [
                    { "id": "repo-00000000000000000001", "name": "First", "root": root },
                    { "id": "repo-00000000000000000001", "name": "Second", "root": root },
                ],
            })
            .to_string(),
        );

        let error = load(&registry).expect_err("duplicate route must fail closed");
        assert!(error.contains("duplicate project id"));
    }
}
