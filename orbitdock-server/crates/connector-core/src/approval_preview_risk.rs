use orbitdock_protocol::{ApprovalRiskLevel, ApprovalType};

#[derive(Debug, Clone)]
pub(super) struct ApprovalRiskAssessment {
  pub(super) level: ApprovalRiskLevel,
  pub(super) findings: Vec<String>,
}

#[derive(Debug, Clone, Copy)]
struct ExecRiskRule {
  pattern: &'static str,
  finding: &'static str,
}

const EXEC_RISK_RULES: &[ExecRiskRule] = &[
  ExecRiskRule {
    pattern: " sudo ",
    finding: "Uses elevated privileges via sudo.",
  },
  ExecRiskRule {
    pattern: " rm -rf",
    finding: "Deletes files recursively with rm -rf.",
  },
  ExecRiskRule {
    pattern: " rm -fr",
    finding: "Deletes files recursively with rm -fr.",
  },
  ExecRiskRule {
    pattern: " git reset --hard",
    finding: "Performs hard git reset and discards local changes.",
  },
  ExecRiskRule {
    pattern: " git clean -fd",
    finding: "Deletes untracked files with git clean -fd.",
  },
  ExecRiskRule {
    pattern: " git clean -xdf",
    finding: "Deletes ignored and untracked files with git clean -xdf.",
  },
  ExecRiskRule {
    pattern: " git push --force",
    finding: "Force-pushes git history.",
  },
  ExecRiskRule {
    pattern: " git push -f",
    finding: "Force-pushes git history.",
  },
  ExecRiskRule {
    pattern: " drop table",
    finding: "Contains SQL DROP TABLE statement.",
  },
  ExecRiskRule {
    pattern: " drop database",
    finding: "Contains SQL DROP DATABASE statement.",
  },
  ExecRiskRule {
    pattern: " truncate table",
    finding: "Contains SQL TRUNCATE TABLE statement.",
  },
  ExecRiskRule {
    pattern: " chmod 777",
    finding: "Sets permissive file mode (chmod 777).",
  },
  ExecRiskRule {
    pattern: " curl | sh",
    finding: "Pipes remote script directly into shell (curl | sh).",
  },
  ExecRiskRule {
    pattern: " wget | sh",
    finding: "Pipes remote script directly into shell (wget | sh).",
  },
  ExecRiskRule {
    pattern: " dd if=",
    finding: "Uses dd with direct device/file writes.",
  },
  ExecRiskRule {
    pattern: " > /dev/",
    finding: "Writes output directly to a /dev device path.",
  },
  ExecRiskRule {
    pattern: " mkfs",
    finding: "Formats a filesystem with mkfs.",
  },
  ExecRiskRule {
    pattern: ":(){ :|:& };:",
    finding: "Contains a shell fork bomb signature.",
  },
];

pub(super) fn assess_approval_risk(
  approval_type: ApprovalType,
  command: Option<&str>,
) -> ApprovalRiskAssessment {
  match approval_type {
    ApprovalType::Question => ApprovalRiskAssessment {
      level: ApprovalRiskLevel::Low,
      findings: vec![],
    },
    ApprovalType::Permissions | ApprovalType::Patch => ApprovalRiskAssessment {
      level: ApprovalRiskLevel::Normal,
      findings: vec![],
    },
    ApprovalType::Exec => {
      let Some(normalized_command) = normalize_command_for_risk(command) else {
        return ApprovalRiskAssessment {
          level: ApprovalRiskLevel::Normal,
          findings: vec![],
        };
      };

      let mut findings: Vec<String> = vec![];
      for rule in EXEC_RISK_RULES {
        if normalized_command.contains(rule.pattern) {
          let finding = rule.finding.to_string();
          if !findings.contains(&finding) {
            findings.push(finding);
          }
        }
      }

      let level = if findings.is_empty() {
        ApprovalRiskLevel::Normal
      } else {
        ApprovalRiskLevel::High
      };
      ApprovalRiskAssessment { level, findings }
    }
  }
}

pub(super) fn approval_type_label(approval_type: ApprovalType) -> &'static str {
  match approval_type {
    ApprovalType::Exec => "exec",
    ApprovalType::Patch => "patch",
    ApprovalType::Question => "question",
    ApprovalType::Permissions => "permissions",
  }
}

pub(super) fn risk_level_label(risk_level: ApprovalRiskLevel) -> &'static str {
  match risk_level {
    ApprovalRiskLevel::Low => "low",
    ApprovalRiskLevel::Normal => "normal",
    ApprovalRiskLevel::High => "high",
  }
}

fn normalize_command_for_risk(command: Option<&str>) -> Option<String> {
  let normalized = super::trim_non_empty(command)?.to_lowercase();
  Some(format!(" {normalized} "))
}
