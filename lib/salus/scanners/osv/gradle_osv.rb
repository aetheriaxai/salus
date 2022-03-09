require 'salus/scanners/osv/base'

module Salus::Scanners::OSV
  class GradleOSV < Base
    class SemVersion < Gem::Version; end

    EMPTY_STRING = "".freeze
    DEFAULT_SOURCE = "https://osv.dev/list".freeze
    DEFAULT_SEVERITY = "MODERATE".freeze
    GITHUB_DATABASE_STRING = "Github Advisory Database".freeze
    GRADLE_OSV_ADVISORY_URL = "https://osv-vulnerabilities.storage.googleapis.com"\
        "/Maven/all.zip".freeze

    def should_run?
      @repository.build_gradle_present?
    end

    def run
      dependencies = find_dependencies
      if dependencies.empty?
        err_msg = "GradleOSV: Failed to parse any dependencies from the project."
        report_stderr(err_msg)
        report_error(err_msg)
        return
      end

      @osv_vulnerabilities ||= fetch_vulnerabilities(GRADLE_OSV_ADVISORY_URL)
      if @osv_vulnerabilities.nil?
        err_msg = "GradleOSV: No vulnerabilities found to compare."
        report_stderr(err_msg)
        report_error(err_msg)
        return
      end

      # Report scanner status
      results = fetch_vulnerable_dependencies(dependencies)
      return report_success if results.empty?

      report_failure
      log(JSON.pretty_generate(results))
    end

    private

    # Match if dependency version found is in the range of
    # vulnerable dependency found.
    def version_matching(version, introduced, fixed)
      vulnerable_flag = false
      version_found = SemVersion.new(version)

      if introduced.present? && fixed.present?
        introduced_version = SemVersion.new(introduced)
        fixed_version = SemVersion.new(fixed)
        if version_found >= introduced_version && version_found < fixed_version
          vulnerable_flag = true
        end
      elsif introduced.present?
        introduced_version = SemVersion.new(introduced)
        vulnerable_flag = true if version_found >= introduced_version
      end

      vulnerable_flag
    end

    # Compare vulnerabilities found with dependencies found
    # and return vulnerable dependencies
    def match_vulnerable_dependencies(dependencies)
      results = []
      dependencies.each do |dependency|
        lib = "#{dependency['group_id']}:#{dependency['artifact_id']}"

        unless dependency['version'].nil?
          version = dependency['version']
          # Cleanup version string.
          version = version.delete("^0-9.").gsub(/\.+$/, "")
          package_matches = @osv_vulnerabilities.select do |v|
            v.dig("package", "name") == lib
          end

          package_matches.each do |match|
            match["ranges"].each do |version_ranges|
              introduced, fixed = vulnerability_info_for(version_ranges)
              if %w[SEMVER ECOSYSTEM].include?(version_ranges["type"]) &&
                  version_matching(version, introduced, fixed)
                results.append(format_vulnerability_result(match, version, introduced, fixed))
              end
            end
          end
        end
      end
      results
    end

    # Find dependencies from the project
    def find_dependencies
      shell_return = run_shell("/home/bin/parse_gradle_deps")
      if !shell_return.success?
        report_error(shell_return.stderr)
        return []
      end

      begin
        dependencies = JSON.parse(shell_return.stdout)
      rescue JSON::ParserError
        err_msg = "GradleOSV: Could not parse JSON returned by bin/parse_gradle_deps's stdout!"
        report_stderr(err_msg)
        report_error(err_msg)
        return []
      end

      # Dedupe dependencies returned.
      uniques = []
      dependencies.group_by { |e| [e["group_id"], e["artifact_id"]] }.each do |_key, values|
        uniques.append(values[0])
      end

      uniques
    end

    def format_vulnerability_result(match, version, introduced, fixed)
      doc = {
        "Package": match.dig("package", "name"),
        "Vulnerable Version": introduced,
        "Version Detected": version,
        "Patched Version": fixed,
        "ID": match.fetch("aliases", [match.fetch("id", [])])[0],
        "Database": match.fetch("database"),
        "Summary": match.fetch("summary", match.dig("details")).strip,
        "References": match.fetch("references", []).collect do |p|
                        p["url"]
                      end.join(", "),
        "Source":  match.dig("database_specific", "url") || DEFAULT_SOURCE,
        "Severity": match.dig("database_specific",
                              "severity") || DEFAULT_SEVERITY
      }
      doc
    end

    def vulnerability_info_for(version_range)
      introduced = version_range["events"]&.first&.[]("introduced")
      fixed = version_range["events"]&.[](1)&.[]("fixed")
      [introduced.nil? ? EMPTY_STRING : introduced, fixed.nil? ? EMPTY_STRING : fixed]
    end

    # Fetch and Dedupe / Select Github Advisory over other sources when available.
    def fetch_vulnerable_dependencies(dependencies)
      results = []
      grouped = match_vulnerable_dependencies(dependencies).group_by { |d| d[:ID] }
      grouped.each do |_key, values|
        vuln = {}
        values.each do |v|
          vuln = v if v[:Database] == GITHUB_DATABASE_STRING
        end
        results.append(vuln.empty? ? values[0] : vuln)
      end
      results
    end
  end
end
