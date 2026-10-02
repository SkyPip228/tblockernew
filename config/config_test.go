package config

import (
	"os"
	"testing"
)

func TestLoadConfig(t *testing.T) {
	configContent := `
LogFile: "/var/log/test.log"
BlockDuration: 15
TorrentTag: "TEST_TORRENT"
UsernameRegex: "user: (\\S+)"
BlockMode: "iptables"
IgnoreEmail: true
BypassIPS:
  - "127.0.0.1"
  - "192.168.1.1"
SendWebhook: true
WebhookURL: "https://test.com/webhook"
WebhookTemplate: '{"test":"%s"}'
StorageDir: "/tmp/test"
WebhookHeaders:
  Authorization: "Bearer test-token"
`

	tmpFile, err := os.CreateTemp("", "config_test_*.yaml")
	if err != nil {
		t.Fatalf("Failed to create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.WriteString(configContent); err != nil {
		t.Fatalf("Failed to write config content: %v", err)
	}
	tmpFile.Close()

	err = LoadConfig(tmpFile.Name())
	if err != nil {
		t.Fatalf("Failed to load config: %v", err)
	}

	if LogFile != "/var/log/test.log" {
		t.Errorf("Expected LogFile '/var/log/test.log', got '%s'", LogFile)
	}
	if len(LogFiles) != 1 || LogFiles[0] != "/var/log/test.log" {
		t.Errorf("Expected legacy LogFile to populate LogFiles, got %#v", LogFiles)
	}

	if BlockDuration != 15 {
		t.Errorf("Expected BlockDuration 15, got %d", BlockDuration)
	}

	if TorrentTag != "TEST_TORRENT" {
		t.Errorf("Expected TorrentTag 'TEST_TORRENT', got '%s'", TorrentTag)
	}

	if BlockMode != "iptables" {
		t.Errorf("Expected BlockMode 'iptables', got '%s'", BlockMode)
	}

	if !SendWebhook {
		t.Error("Expected SendWebhook to be true")
	}

	if !IgnoreEmail {
		t.Error("Expected IgnoreEmail to be true")
	}

	if WebhookURL != "https://test.com/webhook" {
		t.Errorf("Expected WebhookURL 'https://test.com/webhook', got '%s'", WebhookURL)
	}

	if StorageDir != "/tmp/test" {
		t.Errorf("Expected StorageDir '/tmp/test', got '%s'", StorageDir)
	}

	if _, exists := BypassIPSet["127.0.0.1"]; !exists {
		t.Error("Expected 127.0.0.1 to be in BypassIPSet")
	}

	if _, exists := BypassIPSet["192.168.1.1"]; !exists {
		t.Error("Expected 192.168.1.1 to be in BypassIPSet")
	}

	if WebhookHeaders["Authorization"] != "Bearer test-token" {
		t.Errorf("Expected Authorization header 'Bearer test-token', got '%s'", WebhookHeaders["Authorization"])
	}
}

func TestLoadConfigWithDefaults(t *testing.T) {
	configContent := `
LogFile: "/var/log/test.log"
BlockDuration: 10
TorrentTag: "TORRENT"
`

	tmpFile, err := os.CreateTemp("", "config_test_*.yaml")
	if err != nil {
		t.Fatalf("Failed to create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.WriteString(configContent); err != nil {
		t.Fatalf("Failed to write config content: %v", err)
	}
	tmpFile.Close()

	err = LoadConfig(tmpFile.Name())
	if err != nil {
		t.Fatalf("Failed to load config: %v", err)
	}

	if BlockMode != "iptables" {
		t.Errorf("Expected default BlockMode 'iptables', got '%s'", BlockMode)
	}

	if SendWebhook {
		t.Error("Expected default SendWebhook to be false")
	}

	if StorageDir != "/opt/tblocker" {
		t.Errorf("Expected default StorageDir '/opt/tblocker', got '%s'", StorageDir)
	}

	if UsernameRegex == nil {
		t.Error("Expected UsernameRegex to be compiled")
	}
}

func TestLoadConfigInvalidFile(t *testing.T) {
	err := LoadConfig("/nonexistent/file.yaml")
	if err == nil {
		t.Error("Expected error when loading nonexistent file")
	}
}

func TestLoadConfigInvalidYAML(t *testing.T) {
	configContent := `
LogFile: "/var/log/test.log"
BlockDuration: "invalid"
`

	tmpFile, err := os.CreateTemp("", "config_test_*.yaml")
	if err != nil {
		t.Fatalf("Failed to create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.WriteString(configContent); err != nil {
		t.Fatalf("Failed to write config content: %v", err)
	}
	tmpFile.Close()

	err = LoadConfig(tmpFile.Name())
	if err == nil {
		t.Error("Expected error when loading invalid YAML")
	}
}

func TestLoadConfigMultipleLogFiles(t *testing.T) {
	configContent := `
LogFiles:
  - "/var/log/remnanode-a/access.log"
  - "/var/log/remnanode-b/access.log"
  - "/var/log/remnanode-a/access.log"
  - "  "
BlockDuration: 10
TorrentTag: "TORRENT"
`

	tmpFile, err := os.CreateTemp("", "config_test_*.yaml")
	if err != nil {
		t.Fatalf("Failed to create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.WriteString(configContent); err != nil {
		t.Fatalf("Failed to write config content: %v", err)
	}
	tmpFile.Close()

	if err := LoadConfig(tmpFile.Name()); err != nil {
		t.Fatalf("Failed to load config: %v", err)
	}

	if len(LogFiles) != 2 {
		t.Fatalf("Expected 2 unique log files, got %#v", LogFiles)
	}
	if LogFiles[0] != "/var/log/remnanode-a/access.log" || LogFiles[1] != "/var/log/remnanode-b/access.log" {
		t.Errorf("Unexpected LogFiles: %#v", LogFiles)
	}
	if LogFile != LogFiles[0] {
		t.Errorf("Expected legacy LogFile to mirror first LogFiles entry, got %q", LogFile)
	}
}

func TestLoadConfigRequiresLogFile(t *testing.T) {
	configContent := `
BlockDuration: 10
TorrentTag: "TORRENT"
`

	tmpFile, err := os.CreateTemp("", "config_test_*.yaml")
	if err != nil {
		t.Fatalf("Failed to create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name())
	if _, err := tmpFile.WriteString(configContent); err != nil {
		t.Fatalf("Failed to write config content: %v", err)
	}
	tmpFile.Close()

	if err := LoadConfig(tmpFile.Name()); err == nil {
		t.Fatal("Expected error when neither LogFile nor LogFiles is configured")
	}
}
