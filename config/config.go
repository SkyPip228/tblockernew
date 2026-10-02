package config

import (
	"fmt"
	"os"
	"regexp"
	"strings"

	"gopkg.in/yaml.v2"
)

const (
	DefaultNoEmailUsername = "__NO_USER_NAME__"
)

var (
	LogFile       string
	LogFiles      []string
	BlockDuration int
	TorrentTag    string
	BlockMode     string
	BypassIPSet   = make(map[string]struct{})
	IgnoreEmail   bool
	StorageDir    string

	SendWebhook     bool
	WebhookURL      string
	WebhookTemplate string
	WebhookHeaders  map[string]string

	UsernameRegex        *regexp.Regexp
	DefaultUsernameRegex = `^(.+)$`

	Hostname string

	EnablePerformanceMetrics bool
)

type Config struct {
	LogFile         string            `yaml:"LogFile"`
	LogFiles        []string          `yaml:"LogFiles"`
	BlockDuration   int               `yaml:"BlockDuration"`
	TorrentTag      string            `yaml:"TorrentTag"`
	UsernameRegex   string            `yaml:"UsernameRegex"`
	BlockMode       string            `yaml:"BlockMode"`
	BypassIPS       []string          `yaml:"BypassIPS"`
	IgnoreEmail     bool              `yaml:"IgnoreEmail"`
	SendWebhook     bool              `yaml:"SendWebhook"`
	WebhookURL      string            `yaml:"WebhookURL"`
	WebhookTemplate string            `yaml:"WebhookTemplate"`
	StorageDir      string            `yaml:"StorageDir"`
	WebhookHeaders  map[string]string `yaml:"WebhookHeaders"`
	Hostname        string            `yaml:"Hostname"`
}

func LoadConfig(configPath string) error {
	configFile, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}

	var cfg Config
	err = yaml.Unmarshal(configFile, &cfg)
	if err != nil {
		return err
	}

	LogFile = strings.TrimSpace(cfg.LogFile)
	LogFiles = normalizeLogFiles(cfg.LogFiles)
	if len(LogFiles) == 0 && LogFile != "" {
		LogFiles = []string{LogFile}
	}
	if len(LogFiles) == 0 {
		return fmt.Errorf("at least one of LogFile or LogFiles must be configured")
	}
	if LogFile == "" {
		// Keep the legacy global populated for callers that still inspect it.
		LogFile = LogFiles[0]
	}

	BlockDuration = cfg.BlockDuration
	TorrentTag = cfg.TorrentTag
	IgnoreEmail = cfg.IgnoreEmail
	SendWebhook = cfg.SendWebhook
	WebhookURL = cfg.WebhookURL
	WebhookHeaders = cfg.WebhookHeaders

	if cfg.UsernameRegex != "" {
		UsernameRegex, err = regexp.Compile(cfg.UsernameRegex)
	} else {
		UsernameRegex, err = regexp.Compile(DefaultUsernameRegex)
	}
	if err != nil {
		return fmt.Errorf("invalid UsernameRegex pattern: %v", err)
	}

	if cfg.Hostname != "" {
		Hostname = cfg.Hostname
	} else {
		Hostname, err = os.Hostname()
	}

	if cfg.BlockMode != "" {
		BlockMode = cfg.BlockMode
	} else {
		BlockMode = "iptables"
	}
	if cfg.BypassIPS != nil {
		fmt.Println("Bypass IPS list:")
		BypassIPSet = make(map[string]struct{})
		for _, ip := range cfg.BypassIPS {
			BypassIPSet[ip] = struct{}{}
			fmt.Printf("- %s\n", ip)
		}
	} else {
		BypassIPSet = make(map[string]struct{})
	}
	if WebhookHeaders == nil {
		WebhookHeaders = make(map[string]string)
	}
	if cfg.WebhookTemplate != "" {
		WebhookTemplate = cfg.WebhookTemplate
	} else {
		WebhookTemplate = `{"username":"%s","ip":"%s","server":"%s","action":"%s","duration":%d,"timestamp":"%s"}`
	}

	StorageDir = cfg.StorageDir
	if StorageDir == "" {
		StorageDir = "/opt/tblocker"
	}

	return err
}

func normalizeLogFiles(paths []string) []string {
	if len(paths) == 0 {
		return nil
	}

	seen := make(map[string]struct{}, len(paths))
	result := make([]string, 0, len(paths))
	for _, path := range paths {
		path = strings.TrimSpace(path)
		if path == "" {
			continue
		}
		if _, exists := seen[path]; exists {
			continue
		}
		seen[path] = struct{}{}
		result = append(result, path)
	}

	return result
}
