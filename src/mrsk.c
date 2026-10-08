#define _XOPEN_SOURCE 700

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct {
    char *path;
    bool folder;
    bool skip;
} CopyPath;

typedef struct {
    char *name;
    char *project_root;
    char *main_branch;
    char *prefix;
    char *rails_root;
    bool default_project;
    CopyPath *copy_paths;
    size_t copy_path_count;
} Project;

typedef enum {
    CONFIG_NEW,
    CONFIG_LEGACY,
    CONFIG_PROJECTS
} ConfigFormat;

typedef struct {
    Project *projects;
    size_t project_count;
    ConfigFormat format;
    char *redmine_url;
} Config;

typedef struct {
    char *name;
    char *remote;
} GithubRepository;

typedef int (*Command)(Project *, int, char **);

typedef struct {
    const char *name;
    Command run;
} CommandEntry;

static void usage(FILE *stream)
{
    fprintf(stream,
            "Usage:\n"
            "  mrsk configure\n"
            "  mrsk clone <github-repository-url>\n"
            "  mrsk redmine\n"
            "  mrsk review [--from <base> --to <branch> | --commit <sha>]\n"
            "  mrsk rails-schema-confl\n"
            "  mrsk shell-init\n"
            "  mrsk <number-or-issue> [-d|--database]\n"
            "  mrsk [<project>] new [-d|--database] <branch>\n"
            "  mrsk [<project>] open <branch-or-folder>\n"
            "  mrsk [<project>] remove [--force] <branch-or-folder>\n"
            "  mrsk [<project>] delete_all [--force] [--merged]\n"
            "  mrsk [<project>] updater <start|stop|status|run>\n"
            "  mrsk [<project>] bump-migration-version\n"
            "  mrsk [<project>] dbst [--full]\n"
            "  mrsk [<project>] prune [--force]\n"
            "  mrsk [<project>] list\n");
}

static char *trim(char *text)
{
    while (isspace((unsigned char)*text)) {
        text++;
    }

    char *end = text + strlen(text);
    while (end > text && isspace((unsigned char)end[-1])) {
        *--end = '\0';
    }
    return text;
}

static char *copy_value(char *value)
{
    value = trim(value);
    size_t length = strlen(value);
    if (length >= 2 && ((value[0] == '"' && value[length - 1] == '"') ||
                        (value[0] == '\'' && value[length - 1] == '\''))) {
        value[length - 1] = '\0';
        value++;
    }
    return strdup(value);
}

static void free_project(Project *project)
{
    free(project->name);
    free(project->project_root);
    free(project->main_branch);
    free(project->prefix);
    free(project->rails_root);
    for (size_t i = 0; i < project->copy_path_count; i++) {
        free(project->copy_paths[i].path);
    }
    free(project->copy_paths);
}

static void free_config(Config *config)
{
    for (size_t i = 0; i < config->project_count; i++) {
        free_project(&config->projects[i]);
    }
    free(config->projects);
    free(config->redmine_url);
}

static Project *add_project(Config *config)
{
    Project *projects = realloc(config->projects,
                                (config->project_count + 1) * sizeof(*config->projects));
    if (projects == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        return NULL;
    }
    config->projects = projects;
    Project *project = &config->projects[config->project_count++];
    *project = (Project){0};
    return project;
}

static char **project_field(Project *project, const char *key)
{
    if (strcmp(key, "project_name") == 0) {
        return &project->name;
    }
    if (strcmp(key, "project_root") == 0) {
        return &project->project_root;
    }
    if (strcmp(key, "main_branch") == 0) {
        return &project->main_branch;
    }
    if (strcmp(key, "prefix") == 0) {
        return &project->prefix;
    }
    if (strcmp(key, "rails_root") == 0) {
        return &project->rails_root;
    }
    return NULL;
}

static int add_copy_path(Project *project, char *value, bool folder)
{
    CopyPath *items = realloc(project->copy_paths,
                              (project->copy_path_count + 1) * sizeof(*items));
    if (items == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        return 1;
    }
    project->copy_paths = items;
    char *path = copy_value(value);
    if (path == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        return 1;
    }
    items[project->copy_path_count++] = (CopyPath){path, folder, false};
    return 0;
}

static bool valid_copy_path(const char *path)
{
    if (*path == '\0' || *path == '/') {
        return false;
    }

    const char *component = path;
    for (const char *cursor = path;; cursor++) {
        if (*cursor != '/' && *cursor != '\0') {
            continue;
        }
        size_t length = (size_t)(cursor - component);
        if (length == 0 || (length == 1 && component[0] == '.') ||
            (length == 2 && component[0] == '.' && component[1] == '.')) {
            return false;
        }
        if (*cursor == '\0') {
            return true;
        }
        component = cursor + 1;
    }
}

static int config_path(char path[PATH_MAX])
{
    const char *home = getenv("HOME");
    if (home == NULL || *home == '\0') {
        fprintf(stderr, "mrsk: HOME is not set\n");
        return 1;
    }
    if (snprintf(path, PATH_MAX, "%s/.mrsk/config.yml", home) >= PATH_MAX) {
        fprintf(stderr, "mrsk: config path is too long\n");
        return 1;
    }
    return 0;
}

static int load_config(Config *config, bool allow_absent)
{
    char path[PATH_MAX];
    if (config_path(path) != 0) {
        return 1;
    }

    FILE *file = fopen(path, "r");
    if (file == NULL) {
        if (allow_absent && errno == ENOENT) {
            struct stat state;
            if (lstat(path, &state) != 0 && errno == ENOENT) {
                config->format = CONFIG_NEW;
                return 0;
            }
        }
        fprintf(stderr, "mrsk: cannot open %s: %s\n", path, strerror(errno));
        return 1;
    }

    char line[4096];
    unsigned long line_number = 0;
    bool projects_list = false;
    bool content = false;
    Project *project = NULL;
    bool copy_list = false;
    bool copy_folders = false;
    while (fgets(line, sizeof(line), file) != NULL) {
        line_number++;
        if (strchr(line, '\n') == NULL && !feof(file)) {
            fprintf(stderr, "mrsk: %s:%lu: line is too long\n", path, line_number);
            fclose(file);
            return 1;
        }

        size_t indentation = 0;
        while (line[indentation] == ' ') {
            indentation++;
        }

        char *entry = trim(line);
        if (*entry == '\0' || *entry == '#') {
            continue;
        }
        content = true;

        if (indentation == 0 && strncmp(entry, "redmine_url:", 12) == 0) {
            if (config->redmine_url != NULL) {
                fprintf(stderr, "mrsk: %s:%lu: duplicate redmine_url\n", path, line_number);
                fclose(file);
                return 1;
            }
            config->redmine_url = copy_value(entry + 12);
            if (config->redmine_url == NULL) {
                fprintf(stderr, "mrsk: out of memory\n");
                fclose(file);
                return 1;
            }
            if (*config->redmine_url == '\0') {
                fprintf(stderr, "mrsk: %s:%lu: redmine_url cannot be empty\n",
                        path, line_number);
                fclose(file);
                return 1;
            }
            continue;
        }

        if (indentation == 0 && strcmp(entry, "projects:") == 0) {
            if (projects_list || config->project_count != 0) {
                fprintf(stderr, "mrsk: %s:%lu: duplicate or mixed projects configuration\n",
                        path, line_number);
                fclose(file);
                return 1;
            }
            projects_list = true;
            continue;
        }

        size_t list_indentation = projects_list ? 6 : 2;
        if (copy_list && indentation == list_indentation &&
            strncmp(entry, "- ", 2) == 0) {
            if (add_copy_path(project, entry + 2, copy_folders) != 0) {
                fclose(file);
                return 1;
            }
            continue;
        }
        copy_list = false;

        if (projects_list && indentation == 2 && strncmp(entry, "- ", 2) == 0) {
            project = add_project(config);
            if (project == NULL) {
                fclose(file);
                return 1;
            }
            entry = trim(entry + 2);
        } else if (projects_list && (indentation != 4 || project == NULL)) {
            fprintf(stderr,
                    "mrsk: %s:%lu: expected a two-space project item or four-space project field\n",
                    path, line_number);
            fclose(file);
            return 1;
        } else if (!projects_list && indentation != 0) {
            fprintf(stderr, "mrsk: %s:%lu: unexpected indentation\n", path, line_number);
            fclose(file);
            return 1;
        }

        char *separator = strchr(entry, ':');
        if (separator == NULL) {
            fprintf(stderr, "mrsk: %s:%lu: expected key: value\n", path, line_number);
            fclose(file);
            return 1;
        }

        *separator = '\0';
        char *key = trim(entry);
        char *value = trim(separator + 1);
        if (!projects_list && project == NULL) {
            project = add_project(config);
            if (project == NULL) {
                fclose(file);
                return 1;
            }
        }

        if (strcmp(key, "copy_files") == 0 || strcmp(key, "copy_folders") == 0) {
            if (*value != '\0') {
                fprintf(stderr, "mrsk: %s:%lu: expected a list below '%s'\n",
                        path, line_number, key);
                fclose(file);
                return 1;
            }
            copy_list = true;
            copy_folders = strcmp(key, "copy_folders") == 0;
            continue;
        }
        if (strcmp(key, "default") == 0) {
            if (strcmp(value, "true") != 0) {
                fprintf(stderr, "mrsk: %s:%lu: default must be true\n", path, line_number);
                fclose(file);
                return 1;
            }
            project->default_project = true;
            continue;
        }
        char **target = project_field(project, key);
        if (target == NULL || (!projects_list && strcmp(key, "project_name") == 0)) {
            fprintf(stderr, "mrsk: %s:%lu: unknown key '%s'\n", path, line_number, key);
            fclose(file);
            return 1;
        }

        free(*target);
        *target = copy_value(value);
        if (*target == NULL) {
            fprintf(stderr, "mrsk: out of memory\n");
            fclose(file);
            return 1;
        }
    }

    if (ferror(file)) {
        fprintf(stderr, "mrsk: cannot read %s: %s\n", path, strerror(errno));
        fclose(file);
        return 1;
    }
    fclose(file);

    if (config->project_count == 0) {
        if (allow_absent && (!content || projects_list || config->redmine_url != NULL)) {
            config->format = CONFIG_NEW;
            return 0;
        }
        fprintf(stderr, "mrsk: %s must define at least one project\n", path);
        return 1;
    }
    bool default_defined = false;
    for (size_t i = 0; i < config->project_count; i++) {
        Project *item = &config->projects[i];
        if ((projects_list && (item->name == NULL || *item->name == '\0')) ||
            item->project_root == NULL || *item->project_root == '\0' ||
            item->main_branch == NULL || *item->main_branch == '\0') {
            fprintf(stderr,
                    "mrsk: %s: each project must define project_name, project_root, and main_branch\n",
                    path);
            return 1;
        }
        if (item->prefix != NULL && *item->prefix == '\0') {
            fprintf(stderr, "mrsk: %s: prefix cannot be empty\n", path);
            return 1;
        }
        if (item->rails_root != NULL && !valid_copy_path(item->rails_root)) {
            fprintf(stderr, "mrsk: %s: invalid rails_root '%s'\n", path, item->rails_root);
            return 1;
        }
        if (item->default_project && default_defined) {
            fprintf(stderr, "mrsk: %s: only one project can be default\n", path);
            return 1;
        }
        default_defined = default_defined || item->default_project;
        for (size_t j = 0; j < i; j++) {
            if (item->name != NULL && strcmp(item->name, config->projects[j].name) == 0) {
                fprintf(stderr, "mrsk: %s: duplicate project_name '%s'\n", path, item->name);
                return 1;
            }
        }
        for (size_t j = 0; j < item->copy_path_count; j++) {
            if (!valid_copy_path(item->copy_paths[j].path)) {
                fprintf(stderr, "mrsk: %s: invalid %s path '%s'\n", path,
                        item->copy_paths[j].folder ? "copy_folders" : "copy_files",
                        item->copy_paths[j].path);
                return 1;
            }
        }
    }
    config->format = projects_list ? CONFIG_PROJECTS : CONFIG_LEGACY;
    return 0;
}

static int run_process_with_output(char *const argv[], bool quiet, FILE *output)
{
    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "mrsk: fork failed: %s\n", strerror(errno));
        return 125;
    }

    if (pid == 0) {
        if (output != NULL && dup2(fileno(output), STDOUT_FILENO) < 0) {
            fprintf(stderr, "mrsk: cannot redirect output: %s\n", strerror(errno));
            _exit(125);
        }
        if (quiet) {
            FILE *null = fopen("/dev/null", "w");
            if (null != NULL) {
                if (output == NULL) {
                    dup2(fileno(null), STDOUT_FILENO);
                }
                dup2(fileno(null), STDERR_FILENO);
                fclose(null);
            }
        }
        execvp(argv[0], argv);
        fprintf(stderr, "mrsk: cannot run %s: %s\n", argv[0], strerror(errno));
        _exit(127);
    }

    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            fprintf(stderr, "mrsk: waitpid failed: %s\n", strerror(errno));
            return 125;
        }
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static int run_process(char *const argv[], bool quiet)
{
    return run_process_with_output(argv, quiet, NULL);
}

static int command_configure(int argc)
{
    if (argc != 0) {
        usage(stderr);
        return 2;
    }

    char path[PATH_MAX];
    if (config_path(path) != 0) {
        return 1;
    }
    char *file = strrchr(path, '/');
    *file = '\0';
    if (mkdir(path, 0700) != 0 && errno != EEXIST) {
        fprintf(stderr, "mrsk: cannot create %s: %s\n", path, strerror(errno));
        return 1;
    }
    *file = '/';

    char *const command[] = {"vim", path, NULL};
    return run_process(command, false);
}

static int command_review(char **argv)
{
    argv[0] = "ocr";
    execvp(argv[0], argv);
    fprintf(stderr, "mrsk: cannot run ocr: %s\n", strerror(errno));
    return 127;
}

static int command_rails_schema_conflict(int argc)
{
    if (argc != 0) {
        usage(stderr);
        return 2;
    }
    char *const command[] = {
        "ruby", "-e",
        "files = Dir['db/migrate/*.rb'].map { |file| File.basename(file) }.grep(/\\A\\d{14}_/); "
        "abort 'mrsk: no timestamped migrations found in db/migrate' if files.empty?; "
        "raw = files.max[0, 14]; version = [raw[0, 4], raw[4, 2], raw[6, 2], raw[8, 6]].join('_'); "
        "path = 'db/schema.rb'; schema = File.read(path); "
        "conflict = /^<<<<<<<[^\\n]*\\n(ActiveRecord::Schema[^\\n]*define\\(version:\\s*[\\d_]+[^\\n]*\\n)=======\\nActiveRecord::Schema[^\\n]*define\\(version:\\s*[\\d_]+[^\\n]*\\n>>>>>>>[^\\n]*\\n/; "
        "resolved = schema.sub(conflict) { $1.sub(/version:\\s*[\\d_]+/, \"version: #{version}\") }; "
        "abort 'mrsk: db/schema.rb does not contain only a Rails version conflict' if resolved == schema || resolved.match?(/^<<<<<<<|^=======|^>>>>>>>/); "
        "File.write(path, resolved); puts \"Resolved db/schema.rb at version #{version}\"",
        NULL
    };
    return run_process(command, false);
}

static int command_shell_init(int argc)
{
    if (argc != 0) {
        usage(stderr);
        return 2;
    }
    fputs("mrsk() {\n"
          "  local arg name flag ok=1\n"
          "  for arg in \"$@\"; do\n"
          "    if [[ ($arg == -d || $arg == --database) && -z $flag ]]; then\n"
          "      flag=$arg\n"
          "    elif [[ ($arg == <-> || $arg =~ '^[[:alpha:]][[:alnum:]_]*-[0-9]+$') && -z $name ]]; then\n"
          "      name=$arg\n"
          "    else\n"
          "      ok=0\n"
          "    fi\n"
          "  done\n"
          "  if (( ok )) && [[ -n $name ]]; then\n"
          "    local output directory\n"
          "    output=$(command mrsk \"$@\") || return\n"
          "    directory=${output##*$'\\n'}\n"
          "    [[ $output == *$'\\n'* ]] && print -r -- \"${output%$'\\n'*}\"\n"
          "    [[ -d $directory ]] || return 1\n"
          "    builtin cd -- \"$directory\"\n"
          "  else\n"
          "    command mrsk \"$@\"\n"
          "  fi\n"
          "}\n",
          stdout);
    return 0;
}

static char *join_path(const char *root, const char *path)
{
    size_t length = strlen(root) + 1 + strlen(path) + 1;
    char *joined = malloc(length);
    if (joined == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        return NULL;
    }
    snprintf(joined, length, "%s/%s", root, path);
    return joined;
}

static bool ascii_letter(char character)
{
    return (character >= 'A' && character <= 'Z') ||
           (character >= 'a' && character <= 'z');
}

static bool ascii_digit(char character)
{
    return character >= '0' && character <= '9';
}

static bool valid_github_owner(const char *owner)
{
    size_t length = strlen(owner);
    if (length == 0 || length > 39 || owner[0] == '-' || owner[length - 1] == '-') {
        return false;
    }
    for (size_t i = 0; i < length; i++) {
        if (!ascii_letter(owner[i]) && !ascii_digit(owner[i]) && owner[i] != '-') {
            return false;
        }
        if (owner[i] == '-' && i > 0 && owner[i - 1] == '-') {
            return false;
        }
    }
    return true;
}

static bool valid_github_repository_name(const char *name)
{
    size_t length = strlen(name);
    if (length == 0 || length > 100 || strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
        return false;
    }
    for (size_t i = 0; i < length; i++) {
        if (!ascii_letter(name[i]) && !ascii_digit(name[i]) && name[i] != '-' &&
            name[i] != '_' && name[i] != '.') {
            return false;
        }
    }
    return true;
}

static void free_github_repository(GithubRepository *repository)
{
    free(repository->name);
    free(repository->remote);
}

static int parse_github_repository(const char *url, GithubRepository *repository)
{
    const char *https = "https://github.com/";
    const char *ssh = "git@github.com:";
    const char *path;
    bool https_url;
    if (strncmp(url, https, strlen(https)) == 0) {
        path = url + strlen(https);
        https_url = true;
    } else if (strncmp(url, ssh, strlen(ssh)) == 0) {
        path = url + strlen(ssh);
        https_url = false;
    } else {
        fprintf(stderr, "mrsk: invalid GitHub repository URL\n");
        return 1;
    }

    char *components = strdup(path);
    if (components == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        return 1;
    }
    size_t length = strlen(components);
    if (https_url && length > 0 && components[length - 1] == '/') {
        components[--length] = '\0';
    }
    if (length > 4 && strcmp(components + length - 4, ".git") == 0) {
        components[length - 4] = '\0';
    }

    char *slash = strchr(components, '/');
    if (strchr(components, '?') != NULL || strchr(components, '#') != NULL ||
        slash == NULL || strchr(slash + 1, '/') != NULL) {
        fprintf(stderr, "mrsk: invalid GitHub repository URL\n");
        free(components);
        return 1;
    }
    *slash = '\0';
    char *name = slash + 1;
    if (!valid_github_owner(components) || !valid_github_repository_name(name)) {
        fprintf(stderr, "mrsk: invalid GitHub repository URL\n");
        free(components);
        return 1;
    }

    repository->name = strdup(name);
    size_t remote_length = strlen(ssh) + strlen(components) + 1 + strlen(name) +
                           strlen(".git") + 1;
    repository->remote = malloc(remote_length);
    if (repository->name == NULL || repository->remote == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        free(components);
        free_github_repository(repository);
        *repository = (GithubRepository){0};
        return 1;
    }
    snprintf(repository->remote, remote_length, "%s%s/%s.git", ssh, components, name);
    free(components);
    return 0;
}

static char *repository_prefix(const char *name)
{
    char *prefix = malloc(5);
    if (prefix == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        return NULL;
    }
    size_t length = 0;
    for (const char *cursor = name; *cursor != '\0' && length < 4; cursor++) {
        if (*cursor >= 'a' && *cursor <= 'z') {
            prefix[length++] = (char)(*cursor - 'a' + 'A');
        } else if (*cursor >= 'A' && *cursor <= 'Z') {
            prefix[length++] = *cursor;
        }
    }
    if (length == 0) {
        fprintf(stderr, "mrsk: repository name must contain an ASCII letter\n");
        free(prefix);
        return NULL;
    }
    prefix[length] = '\0';
    return prefix;
}

static bool reserved_project_name(const char *name)
{
    static const char *const names[] = {
        "--help", "-h", "__worktree-target-branch-updater-run",
        "configure", "clone", "redmine", "review", "rails-schema-confl", "shell-init",
        "new", "open", "remove", "delete_all", "updater", "daemon", "list",
        "bump-migration-version"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (strcmp(name, names[i]) == 0) {
            return true;
        }
    }
    return false;
}

static char *normalize_absolute_path(const char *path)
{
    char *copy = strdup(path);
    char *normalized = malloc(strlen(path) + 2);
    if (copy == NULL || normalized == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        free(copy);
        free(normalized);
        return NULL;
    }

    size_t length = 1;
    normalized[0] = '/';
    normalized[1] = '\0';
    char *state = NULL;
    for (char *component = strtok_r(copy, "/", &state); component != NULL;
         component = strtok_r(NULL, "/", &state)) {
        if (strcmp(component, ".") == 0) {
            continue;
        }
        if (strcmp(component, "..") == 0) {
            while (length > 1 && normalized[length - 1] != '/') {
                length--;
            }
            if (length > 1) {
                length--;
            }
            normalized[length] = '\0';
            continue;
        }
        if (length > 1) {
            normalized[length++] = '/';
        }
        size_t component_length = strlen(component);
        memcpy(normalized + length, component, component_length);
        length += component_length;
        normalized[length] = '\0';
    }
    free(copy);
    return normalized;
}

static char *canonical_path(const char *path)
{
    char absolute[PATH_MAX];
    if (path[0] == '/') {
        if (snprintf(absolute, sizeof(absolute), "%s", path) >= (int)sizeof(absolute)) {
            fprintf(stderr, "mrsk: path is too long\n");
            return NULL;
        }
    } else {
        char cwd[PATH_MAX];
        if (getcwd(cwd, sizeof(cwd)) == NULL ||
            snprintf(absolute, sizeof(absolute), "%s/%s", cwd, path) >=
                (int)sizeof(absolute)) {
            fprintf(stderr, "mrsk: cannot resolve path: %s\n", strerror(errno));
            return NULL;
        }
    }

    char prefix[PATH_MAX];
    char suffix[PATH_MAX] = "";
    char resolved[PATH_MAX];
    memcpy(prefix, absolute, strlen(absolute) + 1);
    while (realpath(prefix, resolved) == NULL) {
        if (errno != ENOENT && errno != ENOTDIR) {
            fprintf(stderr, "mrsk: cannot resolve %s: %s\n", path, strerror(errno));
            return NULL;
        }
        char *slash = strrchr(prefix, '/');
        if (slash == NULL) {
            fprintf(stderr, "mrsk: cannot resolve %s\n", path);
            return NULL;
        }
        char next[PATH_MAX];
        if (suffix[0] == '\0') {
            if (snprintf(next, sizeof(next), "%s", slash + 1) >= (int)sizeof(next)) {
                fprintf(stderr, "mrsk: path is too long\n");
                return NULL;
            }
        } else if (*(slash + 1) == '\0') {
            if (snprintf(next, sizeof(next), "%s", suffix) >= (int)sizeof(next)) {
                fprintf(stderr, "mrsk: path is too long\n");
                return NULL;
            }
        } else if (snprintf(next, sizeof(next), "%s/%s", slash + 1, suffix) >=
                   (int)sizeof(next)) {
            fprintf(stderr, "mrsk: path is too long\n");
            return NULL;
        }
        memcpy(suffix, next, strlen(next) + 1);
        if (slash == prefix) {
            prefix[1] = '\0';
        } else {
            *slash = '\0';
        }
    }

    char combined[PATH_MAX];
    const char *separator = strcmp(resolved, "/") == 0 || suffix[0] == '\0' ? "" : "/";
    if (snprintf(combined, sizeof(combined), "%s%s%s", resolved, separator, suffix) >=
        (int)sizeof(combined)) {
        fprintf(stderr, "mrsk: path is too long\n");
        return NULL;
    }
    return normalize_absolute_path(combined);
}

static char *legacy_project_name(const char *project_root)
{
    char *path = strdup(project_root);
    if (path == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        return NULL;
    }
    char *name = basename(dirname(path));
    char *result = strcmp(name, ".") == 0 || strcmp(name, "/") == 0 ? NULL : strdup(name);
    if (result == NULL) {
        fprintf(stderr, "mrsk: cannot derive project_name from legacy project_root\n");
    }
    free(path);
    return result;
}

static int prepare_clone_config(Config *config, const char *name, const char *project_root)
{
    if (config->format == CONFIG_LEGACY && config->projects[0].name == NULL) {
        config->projects[0].name = legacy_project_name(config->projects[0].project_root);
        if (config->projects[0].name == NULL) {
            return 1;
        }
    }

    char *candidate = canonical_path(project_root);
    if (candidate == NULL) {
        return 1;
    }
    for (size_t i = 0; i < config->project_count; i++) {
        Project *project = &config->projects[i];
        if (strcmp(project->name, name) == 0) {
            fprintf(stderr, "mrsk: duplicate project_name '%s'\n", name);
            free(candidate);
            return 1;
        }
        char *existing = canonical_path(project->project_root);
        if (existing == NULL) {
            free(candidate);
            return 1;
        }
        if (strcmp(existing, candidate) == 0) {
            fprintf(stderr, "mrsk: duplicate project_root '%s'\n", project_root);
            free(existing);
            free(candidate);
            return 1;
        }
        for (size_t j = 0; j < i; j++) {
            char *previous = canonical_path(config->projects[j].project_root);
            if (previous == NULL) {
                free(existing);
                free(candidate);
                return 1;
            }
            bool duplicate = strcmp(existing, previous) == 0;
            free(previous);
            if (duplicate) {
                fprintf(stderr, "mrsk: duplicate project_root '%s'\n",
                        project->project_root);
                free(existing);
                free(candidate);
                return 1;
            }
        }
        free(existing);
    }
    free(candidate);
    return 0;
}

static char *discover_default_branch(const char *remote)
{
    FILE *output = tmpfile();
    if (output == NULL) {
        fprintf(stderr, "mrsk: cannot create temporary file: %s\n", strerror(errno));
        return NULL;
    }
    char *const command[] = {
        "git", "ls-remote", "--symref", (char *)remote, "HEAD", NULL
    };
    int status = run_process_with_output(command, false, output);
    if (status != 0) {
        fprintf(stderr, "mrsk: cannot determine the remote default branch\n");
        fclose(output);
        return NULL;
    }
    rewind(output);

    const char *prefix = "ref: refs/heads/";
    char *line = NULL;
    char *branch = NULL;
    size_t capacity = 0;
    while (getline(&line, &capacity, output) != -1) {
        line[strcspn(line, "\r\n")] = '\0';
        if (strncmp(line, prefix, strlen(prefix)) != 0) {
            continue;
        }
        char *name = line + strlen(prefix);
        char *tab = strchr(name, '\t');
        if (tab == NULL || strcmp(tab, "\tHEAD") != 0 || tab == name || branch != NULL) {
            free(branch);
            branch = NULL;
            break;
        }
        *tab = '\0';
        branch = strdup(name);
        if (branch == NULL) {
            fprintf(stderr, "mrsk: out of memory\n");
            break;
        }
    }
    bool read_failed = ferror(output);
    free(line);
    fclose(output);
    if (read_failed || branch == NULL) {
        fprintf(stderr, "mrsk: remote has no valid symbolic default branch\n");
        free(branch);
        return NULL;
    }

    size_t branch_length = strlen(branch);
    if (branch_length >= 2 &&
        ((branch[0] == '"' && branch[branch_length - 1] == '"') ||
         (branch[0] == '\'' && branch[branch_length - 1] == '\''))) {
        fprintf(stderr, "mrsk: remote default branch cannot be represented in configuration\n");
        free(branch);
        return NULL;
    }
    return branch;
}

static int write_copy_paths(FILE *file, const Project *project, bool folders)
{
    bool found = false;
    for (size_t i = 0; i < project->copy_path_count; i++) {
        found = found || project->copy_paths[i].folder == folders;
    }
    if (!found) {
        return 0;
    }
    if (fprintf(file, "    %s:\n", folders ? "copy_folders" : "copy_files") < 0) {
        return 1;
    }
    for (size_t i = 0; i < project->copy_path_count; i++) {
        if (project->copy_paths[i].folder == folders &&
            fprintf(file, "      - %s\n", project->copy_paths[i].path) < 0) {
            return 1;
        }
    }
    return 0;
}

static int write_project(FILE *file, const Project *project)
{
    if (fprintf(file,
                "  - project_name: %s\n"
                "    project_root: %s\n"
                "    main_branch: %s\n",
                project->name, project->project_root, project->main_branch) < 0) {
        return 1;
    }
    if (project->prefix != NULL && fprintf(file, "    prefix: %s\n", project->prefix) < 0) {
        return 1;
    }
    if (project->rails_root != NULL &&
        fprintf(file, "    rails_root: %s\n", project->rails_root) < 0) {
        return 1;
    }
    if (project->default_project && fputs("    default: true\n", file) == EOF) {
        return 1;
    }
    return write_copy_paths(file, project, false) || write_copy_paths(file, project, true);
}

static int copy_existing_config(FILE *output, const char *path)
{
    FILE *input = fopen(path, "r");
    if (input == NULL) {
        fprintf(stderr, "mrsk: cannot open %s: %s\n", path, strerror(errno));
        return 1;
    }
    char buffer[4096];
    int last = '\n';
    size_t length;
    while ((length = fread(buffer, 1, sizeof(buffer), input)) > 0) {
        last = (unsigned char)buffer[length - 1];
        if (fwrite(buffer, 1, length, output) != length) {
            fclose(input);
            return 1;
        }
    }
    int status = ferror(input) ? 1 : 0;
    if (fclose(input) != 0) {
        status = 1;
    }
    if (status == 0 && last != '\n' && fputc('\n', output) == EOF) {
        status = 1;
    }
    return status;
}

static int write_clone_config(FILE *file, const char *path, const Config *config,
                              const Project *project)
{
    if (config->format == CONFIG_PROJECTS) {
        if (copy_existing_config(file, path) != 0) {
            return 1;
        }
    } else {
        if (config->redmine_url != NULL &&
            fprintf(file, "redmine_url: %s\n", config->redmine_url) < 0) {
            return 1;
        }
        if (fputs("projects:\n", file) == EOF) {
            return 1;
        }
        if (config->format == CONFIG_LEGACY) {
            for (size_t i = 0; i < config->project_count; i++) {
                if (write_project(file, &config->projects[i]) != 0) {
                    return 1;
                }
            }
        }
    }
    return write_project(file, project);
}

static int validate_clone_config_target(void)
{
    char path[PATH_MAX];
    if (config_path(path) != 0) {
        return 1;
    }
    if (strlen(path) + strlen(".tmp.XXXXXX") >= sizeof(path)) {
        fprintf(stderr, "mrsk: config path is too long\n");
        return 1;
    }
    char *slash = strrchr(path, '/');
    *slash = '\0';

    struct stat state;
    if (stat(path, &state) == 0) {
        if (S_ISDIR(state.st_mode) && access(path, W_OK | X_OK) == 0) {
            return 0;
        }
        fprintf(stderr, "mrsk: config directory is not writable: %s\n", path);
        return 1;
    }
    if (errno != ENOENT) {
        fprintf(stderr, "mrsk: cannot use config directory %s: %s\n",
                path, strerror(errno));
        return 1;
    }
    if (lstat(path, &state) == 0) {
        fprintf(stderr, "mrsk: config directory is not a directory: %s\n", path);
        return 1;
    }
    if (errno != ENOENT) {
        fprintf(stderr, "mrsk: cannot use config directory %s: %s\n",
                path, strerror(errno));
        return 1;
    }

    slash = strrchr(path, '/');
    *slash = '\0';
    if (access(path, W_OK | X_OK) != 0) {
        fprintf(stderr, "mrsk: cannot create config directory in %s: %s\n",
                path, strerror(errno));
        return 1;
    }
    return 0;
}

static int ensure_clone_config_directory(char directory[PATH_MAX], bool *created)
{
    if (config_path(directory) != 0) {
        return 1;
    }
    char *slash = strrchr(directory, '/');
    *slash = '\0';
    *created = false;
    if (mkdir(directory, 0700) == 0) {
        *created = true;
        if (chmod(directory, 0700) == 0) {
            return 0;
        }
        fprintf(stderr, "mrsk: cannot set permissions on %s: %s\n",
                directory, strerror(errno));
        rmdir(directory);
        return 1;
    }
    if (errno != EEXIST) {
        fprintf(stderr, "mrsk: cannot create %s: %s\n", directory, strerror(errno));
        return 1;
    }
    struct stat state;
    if (stat(directory, &state) != 0 || !S_ISDIR(state.st_mode)) {
        fprintf(stderr, "mrsk: config directory is not a directory: %s\n", directory);
        return 1;
    }
    return 0;
}

static int lock_clone_config(void)
{
    char path[PATH_MAX];
    if (config_path(path) != 0) {
        return -1;
    }
    if (strlen(path) + strlen(".lock") >= sizeof(path)) {
        fprintf(stderr, "mrsk: config lock path is too long\n");
        return -1;
    }
    char directory[PATH_MAX];
    bool created_directory;
    if (ensure_clone_config_directory(directory, &created_directory) != 0) {
        return -1;
    }
    strcat(path, ".lock");
    int descriptor = open(path, O_CREAT | O_RDWR, 0600);
    if (descriptor < 0) {
        fprintf(stderr, "mrsk: cannot open config lock %s: %s\n", path, strerror(errno));
        if (created_directory) {
            rmdir(directory);
        }
        return -1;
    }
    if (fchmod(descriptor, 0600) != 0) {
        fprintf(stderr, "mrsk: cannot set config lock permissions: %s\n", strerror(errno));
        close(descriptor);
        return -1;
    }
    struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
    while (fcntl(descriptor, F_SETLKW, &lock) != 0) {
        if (errno == EINTR) {
            continue;
        }
        fprintf(stderr, "mrsk: cannot lock configuration: %s\n", strerror(errno));
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static int save_clone_config(const Config *config, const Project *project)
{
    char path[PATH_MAX];
    if (config_path(path) != 0) {
        return 1;
    }
    struct stat state;
    bool exists = stat(path, &state) == 0;
    if (!exists && errno != ENOENT) {
        fprintf(stderr, "mrsk: cannot inspect %s: %s\n", path, strerror(errno));
        return 1;
    }

    char temporary[PATH_MAX];
    if (snprintf(temporary, sizeof(temporary), "%s.tmp.XXXXXX", path) >=
        (int)sizeof(temporary)) {
        fprintf(stderr, "mrsk: config path is too long\n");
        return 1;
    }
    int descriptor = mkstemp(temporary);
    if (descriptor < 0) {
        fprintf(stderr, "mrsk: cannot create temporary config: %s\n", strerror(errno));
        return 1;
    }
    mode_t mode = exists ? state.st_mode & 07777 : 0600;
    if (fchmod(descriptor, mode) != 0) {
        fprintf(stderr, "mrsk: cannot set config permissions: %s\n", strerror(errno));
        close(descriptor);
        unlink(temporary);
        return 1;
    }

    FILE *file = fdopen(descriptor, "w");
    if (file == NULL) {
        fprintf(stderr, "mrsk: cannot write temporary config: %s\n", strerror(errno));
        close(descriptor);
        unlink(temporary);
        return 1;
    }
    errno = 0;
    int status = write_clone_config(file, path, config, project);
    int saved_errno = errno == 0 ? EIO : errno;
    if (status == 0 && fflush(file) != 0) {
        status = 1;
        saved_errno = errno;
    }
    if (status == 0 && fsync(descriptor) != 0) {
        status = 1;
        saved_errno = errno;
    }
    if (fclose(file) != 0 && status == 0) {
        status = 1;
        saved_errno = errno;
    }
    if (status == 0 && rename(temporary, path) != 0) {
        status = 1;
        saved_errno = errno;
    }
    if (status != 0) {
        fprintf(stderr, "mrsk: cannot update %s: %s\n", path, strerror(saved_errno));
        unlink(temporary);
    }
    return status;
}

static void remove_clone_destination(const char *path)
{
    char *const command[] = {"rm", "-rf", (char *)path, NULL};
    if (run_process(command, false) != 0) {
        fprintf(stderr, "mrsk: cannot remove incomplete clone at %s\n", path);
    }
}

static int command_clone(int argc, char **argv)
{
    if (argc != 1) {
        usage(stderr);
        return 2;
    }

    GithubRepository repository = {0};
    if (parse_github_repository(argv[0], &repository) != 0) {
        return 1;
    }
    if (reserved_project_name(repository.name)) {
        fprintf(stderr, "mrsk: repository name conflicts with an mrsk command: %s\n",
                repository.name);
        free_github_repository(&repository);
        return 1;
    }
    char *prefix = repository_prefix(repository.name);
    Config config = {0};
    char *root = NULL;
    char *checkout = NULL;
    char *branch = NULL;
    int config_lock = -1;
    int status = 1;
    if (prefix == NULL || load_config(&config, true) != 0) {
        goto done;
    }

    char cwd[PATH_MAX];
    if (realpath(".", cwd) == NULL) {
        fprintf(stderr, "mrsk: cannot resolve current directory: %s\n", strerror(errno));
        goto done;
    }
    root = join_path(cwd, repository.name);
    checkout = root == NULL ? NULL : join_path(root, "main");
    if (checkout == NULL || prepare_clone_config(&config, repository.name, checkout) != 0) {
        goto done;
    }
    if (access(cwd, W_OK | X_OK) != 0) {
        fprintf(stderr, "mrsk: current directory is not writable: %s\n", strerror(errno));
        goto done;
    }
    if (validate_clone_config_target() != 0) {
        goto done;
    }

    struct stat destination;
    if (lstat(root, &destination) == 0) {
        fprintf(stderr, "mrsk: destination already exists: %s\n", root);
        goto done;
    }
    if (errno != ENOENT) {
        fprintf(stderr, "mrsk: cannot inspect destination %s: %s\n", root, strerror(errno));
        goto done;
    }

    branch = discover_default_branch(repository.remote);
    if (branch == NULL) {
        goto done;
    }
    if (mkdir(root, 0755) != 0) {
        fprintf(stderr, "mrsk: cannot create %s: %s\n", root, strerror(errno));
        goto done;
    }

    char *const clone[] = {
        "git", "clone", "--origin", "ups", "--branch", branch,
        repository.remote, checkout, NULL
    };
    status = run_process(clone, false);
    if (status != 0) {
        remove_clone_destination(root);
        goto done;
    }

    Project project = {
        .name = repository.name,
        .project_root = checkout,
        .main_branch = branch,
        .prefix = prefix
    };
    config_lock = lock_clone_config();
    if (config_lock < 0) {
        status = 1;
        remove_clone_destination(root);
        goto done;
    }
    free_config(&config);
    config = (Config){0};
    if (load_config(&config, true) != 0 ||
        prepare_clone_config(&config, repository.name, checkout) != 0) {
        status = 1;
        remove_clone_destination(root);
        goto done;
    }
    status = save_clone_config(&config, &project);
    close(config_lock);
    config_lock = -1;
    if (status != 0) {
        remove_clone_destination(root);
        goto done;
    }

    printf("Cloned %s\nDefault branch: %s\nRemote: ups\nPrefix: %s\n",
           checkout, branch, prefix);

done:
    if (config_lock >= 0) {
        close(config_lock);
    }
    free(branch);
    free(checkout);
    free(root);
    free_config(&config);
    free(prefix);
    free_github_repository(&repository);
    return status;
}

static int prepare_copy_paths(Project *project)
{
    for (size_t i = 0; i < project->copy_path_count; i++) {
        CopyPath *copy_path = &project->copy_paths[i];
        char *source = join_path(project->project_root, copy_path->path);
        if (source == NULL) {
            return 1;
        }
        if (access(source, F_OK) != 0) {
            if (copy_path->folder) {
                fprintf(stderr,
                        "\033[33mmrsk: warning: copy folder does not exist: %s\033[0m\n",
                        source);
                copy_path->skip = true;
                free(source);
                continue;
            }
            fprintf(stderr, "mrsk: copy source does not exist: %s\n", source);
            free(source);
            return 1;
        }
        free(source);
    }
    return 0;
}

static int copy_project_path(const Project *project, const char *worktree,
                             const char *path, bool folder)
{
    char *source = join_path(project->project_root, path);
    char *destination = join_path(worktree, path);
    if (source == NULL || destination == NULL) {
        free(source);
        free(destination);
        return 1;
    }
    int status;
    if (folder) {
        char *contents = join_path(source, ".");
        if (contents == NULL) {
            free(source);
            free(destination);
            return 1;
        }
        char *const mkdir_command[] = {"mkdir", "-p", destination, NULL};
        status = run_process(mkdir_command, false);
        if (status == 0) {
            char *const command[] = {"cp", "-R", contents, destination, NULL};
            status = run_process(command, false);
        }
        free(contents);
    } else {
        char *slash = strrchr(destination, '/');
        *slash = '\0';
        char *const mkdir_command[] = {"mkdir", "-p", destination, NULL};
        status = run_process(mkdir_command, false);
        *slash = '/';
        if (status == 0) {
            char *const command[] = {"cp", source, destination, NULL};
            status = run_process(command, false);
        }
    }

    free(source);
    free(destination);
    return status;
}

static int copy_project_paths(const Project *project, const char *worktree)
{
    for (size_t i = 0; i < project->copy_path_count; i++) {
        if (project->copy_paths[i].skip) {
            continue;
        }
        if (copy_project_path(project, worktree, project->copy_paths[i].path,
                              project->copy_paths[i].folder) != 0) {
            return 1;
        }
    }
    return 0;
}

static char *rails_path(const Project *project, const char *checkout)
{
    if (project->rails_root != NULL) {
        return join_path(checkout, project->rails_root);
    }

    char marker[PATH_MAX];
    snprintf(marker, sizeof(marker), "%s/config/database.yml", project->project_root);
    char *result = NULL;
    struct dirent **entries = NULL;
    int count = access(marker, F_OK) == 0 ? 0 :
                scandir(project->project_root, &entries, NULL, alphasort);
    for (int i = 0; i < count; i++) {
        snprintf(marker, sizeof(marker), "%s/%s/config/database.yml",
                 project->project_root, entries[i]->d_name);
        if (result == NULL && entries[i]->d_name[0] != '.' && access(marker, F_OK) == 0) {
            result = join_path(checkout, entries[i]->d_name);
        }
        free(entries[i]);
    }
    free(entries);
    return result != NULL ? result : strdup(checkout);
}

static char *read_env_database_url(const char *dir)
{
    char *path = join_path(dir, ".env");
    if (path == NULL) {
        return NULL;
    }
    FILE *file = fopen(path, "r");
    free(path);
    if (file == NULL) {
        return NULL;
    }

    char line[4096];
    char *url = NULL;
    while (fgets(line, sizeof(line), file) != NULL) {
        if (strncmp(line, "DATABASE_URL=", 13) == 0) {
            url = strdup(trim(line + 13));
            break;
        }
    }
    fclose(file);
    return url;
}

enum { YML_URL, YML_DATABASE, YML_HOST, YML_PORT, YML_USERNAME, YML_PASSWORD, YML_KEY_COUNT };

static char *yml_value(char *value)
{
    value = trim(value);
    if (*value == '"' || *value == '\'') {
        char *close = strchr(value + 1, *value);
        if (close != NULL) {
            close[1] = '\0';
        }
    } else {
        char *comment = strstr(value, " #");
        if (comment != NULL) {
            *comment = '\0';
        }
    }
    return copy_value(value);
}

static bool yml_header(const char *text, const char *name, const char *anchor)
{
    size_t length = strlen(name);
    if (name[0] != '\0' && (strncmp(text, name, length) != 0 || text[length] != ':')) {
        return false;
    }
    if (anchor == NULL) {
        return true;
    }
    const char *mark = strchr(text, '&');
    length = strlen(anchor);
    return mark != NULL && strncmp(mark + 1, anchor, length) == 0 &&
           (mark[1 + length] == '\0' || isspace((unsigned char)mark[1 + length]));
}

static void read_yml_section(FILE *file, const char *name, const char *anchor,
                             char *values[YML_KEY_COUNT], char **merge)
{
    static const char *const keys[YML_KEY_COUNT] = {
        "url:", "database:", "host:", "port:", "username:", "password:"
    };
    char line[4096];
    bool inside = false;
    rewind(file);
    while (fgets(line, sizeof(line), file) != NULL) {
        char *text = trim(line);
        if (*text == '\0' || *text == '#') {
            continue;
        }
        if (!isspace((unsigned char)line[0])) {
            inside = yml_header(text, name, anchor);
            continue;
        }
        if (!inside || strstr(text, "<%") != NULL) {
            continue;
        }
        if (merge != NULL && *merge == NULL && strncmp(text, "<<:", 3) == 0) {
            char *alias = yml_value(text + 3);
            if (alias != NULL && alias[0] == '*') {
                *merge = strdup(alias + 1);
            }
            free(alias);
        }
        for (int i = 0; i < YML_KEY_COUNT; i++) {
            size_t length = strlen(keys[i]);
            if (values[i] == NULL && strncmp(text, keys[i], length) == 0) {
                values[i] = yml_value(text + length);
            }
        }
    }
}

static void put_escaped(FILE *output, const char *text)
{
    for (; *text != '\0'; text++) {
        unsigned char character = (unsigned char)*text;
        if (isalnum(character) || strchr("-._~", character) != NULL) {
            fputc(character, output);
        } else {
            fprintf(output, "%%%02X", character);
        }
    }
}

static char *read_database_yml_url(const char *dir)
{
    char *path = join_path(dir, "config/database.yml");
    if (path == NULL) {
        return NULL;
    }
    FILE *file = fopen(path, "r");
    free(path);
    if (file == NULL) {
        return NULL;
    }

    char *values[YML_KEY_COUNT] = {0};
    char *merge = NULL;
    read_yml_section(file, "development", NULL, values, &merge);
    if (merge != NULL) {
        read_yml_section(file, "", merge, values, NULL);
        free(merge);
    }
    fclose(file);

    char *url = NULL;
    if (values[YML_URL] != NULL) {
        url = values[YML_URL];
        values[YML_URL] = NULL;
    } else if (values[YML_DATABASE] != NULL) {
        const char *host = values[YML_HOST];
        bool socket = host != NULL && host[0] == '/';
        size_t size = 0;
        FILE *output = open_memstream(&url, &size);
        if (output != NULL) {
            fputs("postgresql://", output);
            if (values[YML_USERNAME] != NULL) {
                put_escaped(output, values[YML_USERNAME]);
                if (values[YML_PASSWORD] != NULL) {
                    fputc(':', output);
                    put_escaped(output, values[YML_PASSWORD]);
                }
                fputc('@', output);
            }
            if (host != NULL && !socket) {
                fputs(host, output);
            }
            if (values[YML_PORT] != NULL) {
                fprintf(output, ":%s", values[YML_PORT]);
            }
            fprintf(output, "/%s", values[YML_DATABASE]);
            if (socket) {
                fputs("?host=", output);
                put_escaped(output, host);
            }
            fclose(output);
        }
    }
    for (int i = 0; i < YML_KEY_COUNT; i++) {
        free(values[i]);
    }
    return url;
}

static char *project_database_url(const char *dir)
{
    const char *env = getenv("DATABASE_URL");
    if (env != NULL && *env != '\0') {
        return strdup(env);
    }
    char *url = read_env_database_url(dir);
    return url != NULL ? url : read_database_yml_url(dir);
}

static int url_database(const char *url, const char **name, size_t *length)
{
    const char *scheme = strstr(url, "://");
    const char *slash = scheme != NULL ? strchr(scheme + 3, '/') : NULL;
    if (slash == NULL) {
        return 1;
    }
    *name = slash + 1;
    *length = strcspn(slash + 1, "?");
    return *length == 0 ? 1 : 0;
}

static char *own_database_name(const char *url, const char *worktree)
{
    const char *database;
    size_t length;
    if (url_database(url, &database, &length) != 0) {
        return NULL;
    }

    const char *base = strrchr(worktree, '/');
    base = base != NULL ? base + 1 : worktree;
    size_t base_length = strlen(base);
    char *name = malloc(length + 1 + base_length + 1);
    if (name == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        return NULL;
    }
    memcpy(name, database, length);
    name[length] = '_';
    for (size_t i = 0; i < base_length; i++) {
        unsigned char character = (unsigned char)base[i];
        name[length + 1 + i] = isalnum(character) ? (char)character : '_';
    }
    name[length + 1 + base_length] = '\0';
    return name;
}

static char *url_with_database(const char *url, const char *name)
{
    const char *database;
    size_t length;
    if (url_database(url, &database, &length) != 0) {
        fprintf(stderr, "mrsk: DATABASE_URL has no database name\n");
        return NULL;
    }
    size_t prefix = (size_t)(database - url);
    size_t total = prefix + strlen(name) + strlen(database + length) + 1;
    char *result = malloc(total);
    if (result == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        return NULL;
    }
    snprintf(result, total, "%.*s%s%s", (int)prefix, url, name, database + length);
    return result;
}

static int run_database_sql(const char *url, const char *sql)
{
    char *admin = url_with_database(url, "postgres");
    if (admin == NULL) {
        return 1;
    }
    char *const command[] = {
        "psql", admin, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", (char *)sql, NULL
    };
    int status = run_process(command, false);
    free(admin);
    return status;
}

static int rewrite_env_database(const char *dir, const char *url)
{
    char *path = join_path(dir, ".env");
    if (path == NULL) {
        return 1;
    }

    char *buffer = NULL;
    size_t size = 0;
    FILE *output = open_memstream(&buffer, &size);
    if (output == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        free(path);
        return 1;
    }
    bool replaced = false;
    FILE *file = fopen(path, "r");
    if (file != NULL) {
        char line[4096];
        while (fgets(line, sizeof(line), file) != NULL) {
            if (!replaced && strncmp(line, "DATABASE_URL=", 13) == 0) {
                fprintf(output, "DATABASE_URL=%s\n", url);
                replaced = true;
            } else {
                fputs(line, output);
            }
        }
        fclose(file);
    }
    if (!replaced) {
        fprintf(output, "DATABASE_URL=%s\n", url);
    }
    if (fclose(output) != 0 || buffer == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        free(buffer);
        free(path);
        return 1;
    }

    FILE *result = fopen(path, "w");
    int status = 0;
    if (result == NULL || fwrite(buffer, 1, size, result) != size) {
        status = 1;
    }
    if (result != NULL && fclose(result) != 0) {
        status = 1;
    }
    if (status != 0) {
        fprintf(stderr, "mrsk: cannot write %s: %s\n", path, strerror(errno));
    }
    free(buffer);
    free(path);
    return status;
}

static int create_worktree_database(const Project *project, const char *worktree)
{
    char *main_rails = rails_path(project, project->project_root);
    char *url = main_rails != NULL ? project_database_url(main_rails) : NULL;
    if (url == NULL) {
        fprintf(stderr, "mrsk: no DATABASE_URL in the environment, %s/.env, or config/database.yml\n",
                main_rails != NULL ? main_rails : project->project_root);
        free(main_rails);
        return 1;
    }
    free(main_rails);

    const char *source;
    size_t source_length;
    int status = 1;
    if (url_database(url, &source, &source_length) != 0) {
        fprintf(stderr, "mrsk: DATABASE_URL has no database name\n");
        free(url);
        return 1;
    }

    char *name = own_database_name(url, worktree);
    char *sql = NULL;
    char *worktree_url = NULL;
    if (name != NULL) {
        size_t sql_length = strlen("CREATE DATABASE \"\" TEMPLATE \"\"") +
                            strlen(name) + source_length + 1;
        sql = malloc(sql_length);
        if (sql == NULL) {
            fprintf(stderr, "mrsk: out of memory\n");
        } else {
            snprintf(sql, sql_length, "CREATE DATABASE \"%s\" TEMPLATE \"%.*s\"",
                     name, (int)source_length, source);
            status = run_database_sql(url, sql);
            if (status == 0) {
                worktree_url = url_with_database(url, name);
                char *rails = rails_path(project, worktree);
                status = worktree_url != NULL && rails != NULL ?
                         rewrite_env_database(rails, worktree_url) : 1;
                free(rails);
                if (status != 0) {
                    snprintf(sql, sql_length, "DROP DATABASE IF EXISTS \"%s\"", name);
                    run_database_sql(url, sql);
                }
            }
            if (status == 0) {
                printf("Created database %s\n", name);
            }
        }
    }

    free(worktree_url);
    free(sql);
    free(name);
    free(url);
    return status;
}

static char *worktree_own_database(const Project *project, const char *path)
{
    char *rails = rails_path(project, path);
    char *worktree_url = rails != NULL ? read_env_database_url(rails) : NULL;
    free(rails);
    if (worktree_url == NULL) {
        return NULL;
    }
    rails = rails_path(project, project->project_root);
    char *main_url = rails != NULL ? project_database_url(rails) : NULL;
    free(rails);
    char *expected = main_url != NULL ? own_database_name(main_url, path) : NULL;

    char *result = NULL;
    const char *database;
    size_t length;
    if (expected != NULL && url_database(worktree_url, &database, &length) == 0 &&
        strlen(expected) == length && strncmp(expected, database, length) == 0) {
        result = expected;
        expected = NULL;
    }
    free(expected);
    free(main_url);
    free(worktree_url);
    return result;
}

static bool has_new_migrations(const Project *project, const char *worktree)
{
    char *rails = rails_path(project, worktree);
    char *worktree_dir = rails != NULL ? join_path(rails, "db/migrate") : NULL;
    free(rails);
    if (worktree_dir == NULL) {
        return false;
    }
    DIR *dir = opendir(worktree_dir);
    free(worktree_dir);
    if (dir == NULL) {
        return false;
    }

    rails = rails_path(project, project->project_root);
    char *main_dir = rails != NULL ? join_path(rails, "db/migrate") : NULL;
    free(rails);
    if (main_dir == NULL) {
        closedir(dir);
        return false;
    }
    bool found = false;
    struct dirent *entry;
    while (!found && (entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') {
            continue;
        }
        char *candidate = join_path(main_dir, entry->d_name);
        if (candidate == NULL) {
            break;
        }
        found = access(candidate, F_OK) != 0;
        free(candidate);
    }
    free(main_dir);
    closedir(dir);
    return found;
}

static void start_background_migration(const Project *project, const char *checkout)
{
    char *worktree = rails_path(project, checkout);
    if (worktree == NULL) {
        return;
    }
    char *tmp_dir = join_path(worktree, "tmp");
    if (tmp_dir == NULL) {
        free(worktree);
        return;
    }
    if (mkdir(tmp_dir, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "mrsk: cannot create %s: %s\n", tmp_dir, strerror(errno));
        free(tmp_dir);
        free(worktree);
        return;
    }
    free(tmp_dir);

    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "mrsk: cannot start migration: %s\n", strerror(errno));
        free(worktree);
        return;
    }
    if (pid == 0) {
        if (chdir(worktree) != 0) {
            _exit(127);
        }
        setsid();
        int null = open("/dev/null", O_RDONLY);
        if (null >= 0) {
            dup2(null, STDIN_FILENO);
            close(null);
        }
        int log = open("tmp/mrsk-migrate.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (log >= 0) {
            dup2(log, STDOUT_FILENO);
            dup2(log, STDERR_FILENO);
            close(log);
        }
        char *const command[] = {
            "/bin/sh", "-c",
            "echo $$ > tmp/mrsk-migrate.pid; "
            "bin/rails db:migrate; "
            "echo $? > tmp/mrsk-migrate.status",
            NULL
        };
        execv("/bin/sh", command);
        _exit(127);
    }
    printf("Migrating in background (log: %s/tmp/mrsk-migrate.log)\n", worktree);
    free(worktree);
}

static const char *migration_status(const char *path)
{
    char *file = join_path(path, "tmp/mrsk-migrate.status");
    if (file == NULL) {
        return NULL;
    }
    FILE *status = fopen(file, "r");
    free(file);
    if (status != NULL) {
        int character = fgetc(status);
        fclose(status);
        return character == '0' ? "migrated" : "migrate failed";
    }

    file = join_path(path, "tmp/mrsk-migrate.pid");
    if (file == NULL) {
        return NULL;
    }
    FILE *pid_file = fopen(file, "r");
    free(file);
    if (pid_file == NULL) {
        return NULL;
    }
    long pid = 0;
    int matched = fscanf(pid_file, "%ld", &pid);
    fclose(pid_file);
    if (matched != 1 || pid <= 0) {
        return NULL;
    }
    return kill((pid_t)pid, 0) == 0 ? "migrating" : "migrate interrupted";
}

static char *worktree_path(const Project *project, const char *name)
{
    const char *slash = strrchr(project->project_root, '/');
    if (slash == NULL || slash == project->project_root || slash[1] == '\0') {
        fprintf(stderr, "mrsk: project_root must be an absolute checkout path\n");
        return NULL;
    }

    size_t parent_length = (size_t)(slash - project->project_root);
    size_t name_length = strlen(name);
    char *path = malloc(parent_length + 1 + name_length + 1);
    if (path == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        return NULL;
    }

    memcpy(path, project->project_root, parent_length);
    path[parent_length] = '/';
    for (size_t i = 0; i < name_length; i++) {
        char character = name[i];
        path[parent_length + 1 + i] = character == '/' ? '-' : character;
    }
    path[parent_length + 1 + name_length] = '\0';
    return path;
}

static bool numeric_name(const char *name)
{
    return *name != '\0' && strspn(name, "0123456789") == strlen(name);
}

static int command_redmine(const Config *config, int argc)
{
    if (argc != 0) {
        usage(stderr);
        return 2;
    }
    if (config->redmine_url == NULL) {
        fprintf(stderr, "mrsk: redmine_url is not configured in ~/.mrsk/config.yml\n");
        return 1;
    }

    FILE *output = tmpfile();
    if (output == NULL) {
        fprintf(stderr, "mrsk: cannot create temporary file: %s\n", strerror(errno));
        return 1;
    }
    char *const branch_command[] = {
        "git", "symbolic-ref", "--quiet", "--short", "HEAD", NULL
    };
    int status = run_process_with_output(branch_command, false, output);
    if (status != 0) {
        fprintf(stderr, "mrsk: current checkout has no branch\n");
        fclose(output);
        return 1;
    }
    rewind(output);

    char *branch = NULL;
    size_t capacity = 0;
    if (getline(&branch, &capacity, output) == -1) {
        fprintf(stderr, "mrsk: cannot read current branch\n");
        free(branch);
        fclose(output);
        return 1;
    }
    fclose(output);
    branch[strcspn(branch, "\r\n")] = '\0';
    char *separator = strrchr(branch, '-');
    const char *issue = separator == NULL ? "" : separator + 1;
    if (!numeric_name(issue)) {
        fprintf(stderr, "mrsk: current branch does not end with an issue number: %s\n", branch);
        free(branch);
        return 1;
    }

    size_t base_length = strlen(config->redmine_url);
    while (base_length > 0 && config->redmine_url[base_length - 1] == '/') {
        base_length--;
    }
    const char *scheme = strstr(config->redmine_url, "://") == NULL ? "https://" : "";
    size_t url_length = strlen(scheme) + base_length + strlen("/issues/") + strlen(issue) + 1;
    char *url = malloc(url_length);
    if (url == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        free(branch);
        return 1;
    }
    snprintf(url, url_length, "%s%.*s/issues/%s",
             scheme, (int)base_length, config->redmine_url, issue);
#ifdef __APPLE__
    char *const open_command[] = {"open", url, NULL};
#else
    char *const open_command[] = {"xdg-open", url, NULL};
#endif
    status = run_process(open_command, false);
    free(url);
    free(branch);
    return status;
}

static bool prefixed_number_name(const char *name)
{
    const unsigned char *cursor = (const unsigned char *)name;
    if (!isalpha(*cursor)) {
        return false;
    }
    for (cursor++; isalnum(*cursor) || *cursor == '_'; cursor++) {
    }
    return *cursor == '-' && numeric_name((const char *)cursor + 1);
}

static bool shortcut_name(const char *name)
{
    return numeric_name(name) || prefixed_number_name(name);
}

static char *project_branch_name(const Project *project, const char *name)
{
    if (project->prefix == NULL || !numeric_name(name)) {
        return strdup(name);
    }

    size_t length = strlen(project->prefix) + 1 + strlen(name) + 1;
    char *branch = malloc(length);
    if (branch == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        return NULL;
    }
    snprintf(branch, length, "%s-%s", project->prefix, name);
    return branch;
}

static int validate_branch(const Project *project, const char *branch)
{
    char *const argv[] = {
        "git", "-C", project->project_root, "check-ref-format", "--branch", (char *)branch, NULL
    };
    int status = run_process(argv, true);
    if (status != 0) {
        fprintf(stderr, "mrsk: invalid branch name '%s'\n", branch);
        return 1;
    }
    return 0;
}

static bool local_branch_exists(const Project *project, const char *branch, int *error)
{
    size_t length = strlen("refs/heads/") + strlen(branch) + 1;
    char *ref = malloc(length);
    if (ref == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        *error = 1;
        return false;
    }
    snprintf(ref, length, "refs/heads/%s", branch);

    char *const argv[] = {
        "git", "-C", project->project_root, "show-ref", "--verify", "--quiet", ref, NULL
    };
    int status = run_process(argv, true);
    free(ref);
    if (status > 1) {
        fprintf(stderr, "mrsk: could not inspect local branches\n");
        *error = 1;
    }
    return status == 0;
}

// Undo a half-made `new`: remove the worktree, and the branch when this run created it.
static void rollback_worktree(const Project *project, const char *path, const char *branch)
{
    char *const remove_command[] = {
        "git", "-C", project->project_root, "worktree", "remove", "--force", "--", (char *)path, NULL
    };
    char *const delete_command[] = {
        "git", "-C", project->project_root, "branch", "-D", "--", (char *)branch, NULL
    };
    int status = run_process(remove_command, false);
    if (status == 0 && branch != NULL) {
        status = run_process(delete_command, false);
    }
    if (status == 0) {
        fprintf(stderr, "mrsk: rolled back %s\n", path);
    } else {
        fprintf(stderr, "mrsk: rollback failed, clean up %s by hand\n", path);
    }
}

static int create_worktree(Project *project, const char *branch, bool database)
{
    if (validate_branch(project, branch) != 0) {
        return 1;
    }

    char *path = worktree_path(project, branch);
    if (path == NULL) {
        return 1;
    }
    if (access(path, F_OK) == 0) {
        fprintf(stderr, "mrsk: destination already exists: %s\n", path);
        free(path);
        return 1;
    }
    if (prepare_copy_paths(project) != 0) {
        free(path);
        return 1;
    }
    if (database) {
        char *rails = rails_path(project, project->project_root);
        char *url = rails != NULL ? project_database_url(rails) : NULL;
        const char *name;
        size_t length;
        if (url == NULL || url_database(url, &name, &length) != 0) {
            fprintf(stderr,
                    "mrsk: --database needs a database name in DATABASE_URL, %s/.env, or config/database.yml\n",
                    rails != NULL ? rails : project->project_root);
            free(rails);
            free(url);
            free(path);
            return 1;
        }
        free(rails);
        free(url);
    }

    int error = 0;
    bool exists = local_branch_exists(project, branch, &error);
    if (error != 0) {
        free(path);
        return 1;
    }

    int status;
    if (exists) {
        char *const command[] = {
            "git", "-C", project->project_root, "worktree", "add", "--", path, (char *)branch, NULL
        };
        status = run_process(command, false);
    } else {
        char *const command[] = {
            "git", "-C", project->project_root, "worktree", "add", "-b", (char *)branch,
            "--", path, project->main_branch, NULL
        };
        status = run_process(command, false);
    }
    bool worktree_added = status == 0;

    if (status == 0) {
        status = copy_project_paths(project, path);
    }
    if (status == 0 && database) {
        status = create_worktree_database(project, path);
        if (status == 0 && has_new_migrations(project, path)) {
            start_background_migration(project, path);
        }
    }
    if (status == 0) {
        printf("Created %s\n", path);
    } else if (worktree_added) {
        rollback_worktree(project, path, exists ? NULL : branch);
    }
    free(path);
    return status;
}

static bool database_flag(const char *arg)
{
    return strcmp(arg, "-d") == 0 || strcmp(arg, "--database") == 0;
}

static const char *database_args(int argc, char **argv, bool *database)
{
    *database = false;
    const char *name = NULL;
    for (int i = 0; i < argc; i++) {
        if (database_flag(argv[i]) && !*database) {
            *database = true;
        } else if (name == NULL) {
            name = argv[i];
        } else {
            return NULL;
        }
    }
    return name != NULL && *name != '\0' ? name : NULL;
}

static int command_new(Project *project, int argc, char **argv)
{
    bool database;
    const char *name = database_args(argc, argv, &database);
    if (name == NULL) {
        usage(stderr);
        return 2;
    }

    char *branch = project_branch_name(project, name);
    if (branch == NULL) {
        return 1;
    }
    int status = create_worktree(project, branch, database);
    free(branch);
    return status;
}

static int command_switch(Project *project, int argc, char **argv)
{
    bool database;
    const char *name = database_args(argc, argv, &database);
    if (name == NULL) {
        usage(stderr);
        return 2;
    }

    char *branch = project_branch_name(project, name);
    if (branch == NULL) {
        return 1;
    }
    char *path = worktree_path(project, branch);
    if (path == NULL) {
        free(branch);
        return 1;
    }

    int status = 0;
    if (access(path, F_OK) != 0) {
        status = create_worktree(project, branch, database);
    } else if (database) {
        char *existing = worktree_own_database(project, path);
        if (existing == NULL) {
            status = create_worktree_database(project, path);
            if (status == 0 && has_new_migrations(project, path)) {
                start_background_migration(project, path);
            }
        }
        free(existing);
    }
    if (status == 0) {
        printf("%s\n", path);
    }
    free(path);
    free(branch);
    return status;
}

static int command_open(Project *project, int argc, char **argv)
{
    if (argc != 1) {
        usage(stderr);
        return 2;
    }

    char *path = worktree_path(project, argv[0]);
    if (path == NULL) {
        return 1;
    }
    if (access(path, F_OK) != 0) {
        fprintf(stderr, "mrsk: worktree does not exist: %s\n", path);
        free(path);
        return 1;
    }

#ifdef __APPLE__
    char *const command[] = {"open", "-a", "Terminal", path, NULL};
    int status = run_process(command, false);
#else
    fprintf(stderr, "mrsk: open is supported on macOS only\n");
    int status = 1;
#endif
    free(path);
    return status;
}

static int remove_worktree(Project *project, const char *path, bool force)
{
    char *database = worktree_own_database(project, path);
    char *rails = database != NULL ? rails_path(project, path) : NULL;
    char *url = rails != NULL ? read_env_database_url(rails) : NULL;
    free(rails);

    char *normal[] = {
        "git", "-C", project->project_root, "worktree", "remove", "--", (char *)path, NULL
    };
    char *forced[] = {
        "git", "-C", project->project_root, "worktree", "remove", "--force",
        "--", (char *)path, NULL
    };
    int status = run_process(force ? forced : normal, false);
    if (status == 0) {
        printf("Removed %s\n", path);
    }

    if (status == 0 && database != NULL && url != NULL) {
        size_t length = strlen("DROP DATABASE IF EXISTS \"\"") + strlen(database) + 1;
        char *sql = malloc(length);
        if (sql == NULL) {
            fprintf(stderr, "mrsk: out of memory\n");
            status = 1;
        } else {
            snprintf(sql, length, "DROP DATABASE IF EXISTS \"%s\"", database);
            status = run_database_sql(url, sql);
            if (status == 0) {
                printf("Removed database %s\n", database);
            }
            free(sql);
        }
    }
    free(url);
    free(database);
    return status;
}

static int command_remove(Project *project, int argc, char **argv)
{
    bool force = false;
    const char *name = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--force") == 0 && !force) {
            force = true;
        } else if (name == NULL) {
            name = argv[i];
        } else {
            usage(stderr);
            return 2;
        }
    }
    if (name == NULL || *name == '\0') {
        usage(stderr);
        return 2;
    }

    char *path = worktree_path(project, name);
    if (path == NULL) {
        return 1;
    }
    if (strcmp(path, project->project_root) == 0) {
        fprintf(stderr, "mrsk: refusing to remove the configured main checkout\n");
        free(path);
        return 1;
    }

    int status = remove_worktree(project, path, force);
    free(path);
    return status;
}

static bool protected_branch(const char *branch)
{
    const char *list = getenv("GIT_PROTECTED_BRANCHES");
    if (branch == NULL || list == NULL) {
        return false;
    }

    size_t branch_length = strlen(branch);
    while (*list != '\0') {
        list += strspn(list, ", \t\r\n");
        size_t length = strcspn(list, ", \t\r\n");
        if (length == branch_length && strncmp(list, branch, length) == 0) {
            return true;
        }
        list += length;
    }
    return false;
}

static int command_delete_all(Project *project, int argc, char **argv)
{
    bool force = false;
    bool merged = false;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--force") == 0 && !force) {
            force = true;
        } else if (strcmp(argv[i], "--merged") == 0 && !merged) {
            merged = true;
        } else {
            usage(stderr);
            return 2;
        }
    }

    char main_path[PATH_MAX];
    if (realpath(project->project_root, main_path) == NULL) {
        fprintf(stderr, "mrsk: cannot resolve %s: %s\n",
                project->project_root, strerror(errno));
        return 1;
    }

    FILE *output = tmpfile();
    if (output == NULL) {
        fprintf(stderr, "mrsk: cannot create temporary file: %s\n", strerror(errno));
        return 1;
    }
    char *const list[] = {
        "git", "-C", project->project_root, "worktree", "list", "--porcelain", "-z", NULL
    };
    int status = run_process_with_output(list, false, output);
    if (status != 0) {
        fclose(output);
        return status;
    }
    rewind(output);

    char *entry = NULL;
    char *path = NULL;
    char *branch = NULL;
    size_t capacity = 0;
    int result = 0;
    while (getdelim(&entry, &capacity, '\0', output) != -1) {
        if (strncmp(entry, "worktree ", 9) == 0) {
            free(path);
            path = strdup(entry + 9);
        } else if (strncmp(entry, "branch refs/heads/", 18) == 0) {
            free(branch);
            branch = strdup(entry + 18);
        } else if (*entry == '\0' && path != NULL) {
            bool skip = strcmp(path, main_path) == 0 || protected_branch(branch);
            if (!skip && merged) {
                // ponytail: same notion as `git branch --merged`, so squash merges are kept.
                char *const ancestor[] = {
                    "git", "-C", project->project_root, "merge-base", "--is-ancestor",
                    branch, project->main_branch, NULL
                };
                skip = branch == NULL || run_process(ancestor, false) != 0;
            }
            if (!skip) {
                status = remove_worktree(project, path, force);
                if (status == 0) {
                    if (branch != NULL) {
                        char *const remove_branch[] = {
                            "git", "-C", project->project_root, "branch", "-D", "--", branch, NULL
                        };
                        status = run_process(remove_branch, false);
                    }
                }
                if (status != 0) {
                    result = status;
                }
            }
            free(path);
            free(branch);
            path = NULL;
            branch = NULL;
        }
        if ((path == NULL && strncmp(entry, "worktree ", 9) == 0) ||
            (branch == NULL && strncmp(entry, "branch refs/heads/", 18) == 0)) {
            fprintf(stderr, "mrsk: out of memory\n");
            result = 1;
            break;
        }
    }

    free(entry);
    free(path);
    free(branch);
    fclose(output);
    return result;
}

static int command_list(Project *project, int argc, char **argv)
{
    (void)argv;
    if (argc != 0) {
        usage(stderr);
        return 2;
    }

    FILE *output = tmpfile();
    if (output == NULL) {
        fprintf(stderr, "mrsk: cannot create temporary file: %s\n", strerror(errno));
        return 1;
    }
    char *const command[] = {
        "git", "-C", project->project_root, "worktree", "list", "--porcelain", "-z", NULL
    };
    int status = run_process_with_output(command, false, output);
    if (status != 0) {
        fclose(output);
        return status;
    }
    rewind(output);

    char *entry = NULL;
    char *path = NULL;
    char *head = NULL;
    char *branch = NULL;
    bool detached = false;
    size_t capacity = 0;
    int result = 0;
    while (getdelim(&entry, &capacity, '\0', output) != -1) {
        if (strncmp(entry, "worktree ", 9) == 0) {
            free(path);
            path = strdup(entry + 9);
        } else if (strncmp(entry, "HEAD ", 5) == 0) {
            free(head);
            head = strdup(entry + 5);
        } else if (strncmp(entry, "branch refs/heads/", 18) == 0) {
            free(branch);
            branch = strdup(entry + 18);
        } else if (strcmp(entry, "detached") == 0) {
            detached = true;
        } else if (*entry == '\0' && path != NULL) {
            char *database = worktree_own_database(project, path);
            printf("%s", path);
            if (head != NULL) {
                printf("  %.7s", head);
            }
            if (branch != NULL) {
                printf(" [%s]", branch);
            } else if (detached) {
                printf(" (detached HEAD)");
            }
            if (database != NULL) {
                printf(" [database: %s]", database);
            }
            char *rails = rails_path(project, path);
            const char *migration = rails != NULL ? migration_status(rails) : NULL;
            free(rails);
            if (migration != NULL) {
                printf(" [%s]", migration);
            }
            putchar('\n');
            free(database);
            free(path);
            free(head);
            free(branch);
            path = NULL;
            head = NULL;
            branch = NULL;
            detached = false;
        }
        if ((path == NULL && strncmp(entry, "worktree ", 9) == 0) ||
            (head == NULL && strncmp(entry, "HEAD ", 5) == 0) ||
            (branch == NULL && strncmp(entry, "branch refs/heads/", 18) == 0)) {
            fprintf(stderr, "mrsk: out of memory\n");
            result = 1;
            break;
        }
    }

    free(entry);
    free(path);
    free(head);
    free(branch);
    fclose(output);
    return result;
}

static bool mentions(const char *text, const char *name)
{
    size_t length = strlen(name);
    for (const char *at = text; text != NULL && (at = strstr(at, name)) != NULL; at++) {
        unsigned char before = at == text ? ' ' : (unsigned char)at[-1];
        unsigned char after = (unsigned char)at[length];
        if (!isalnum(before) && before != '_' && !isalnum(after) && after != '_') {
            return true;
        }
    }
    return false;
}

static int command_prune(Project *project, int argc, char **argv)
{
    bool force = argc == 1 && strcmp(argv[0], "--force") == 0;
    if (argc != (force ? 1 : 0)) {
        usage(stderr);
        return 2;
    }

    char *rails = rails_path(project, project->project_root);
    char *url = rails != NULL ? project_database_url(rails) : NULL;
    char *yml_path = rails != NULL ? join_path(rails, "config/database.yml") : NULL;
    FILE *yml = yml_path != NULL ? fopen(yml_path, "r") : NULL;
    char *config = NULL;
    size_t config_size = 0;
    char *kept = NULL;
    size_t kept_size = 0;
    FILE *keep = open_memstream(&kept, &kept_size);
    FILE *output = tmpfile();
    char *line = NULL;
    size_t capacity = 0;
    size_t found = 0;
    int status = 1;
    const char *database;
    size_t length;
    if (url == NULL || url_database(url, &database, &length) != 0) {
        fprintf(stderr, "mrsk: no development database found in DATABASE_URL, .env or config/database.yml\n");
        goto done;
    }
    if (keep == NULL || output == NULL) {
        fprintf(stderr, "mrsk: out of memory\n");
        goto done;
    }
    // ponytail: names in database.yml (Rails 8 app_development_cache etc.) are never orphans
    if (yml != NULL && getdelim(&config, &config_size, '\0', yml) == -1) {
        free(config);
        config = NULL;
    }

    char *const worktrees[] = {
        "git", "-C", project->project_root, "worktree", "list", "--porcelain", "-z", NULL
    };
    status = run_process_with_output(worktrees, false, output);
    if (status != 0) {
        goto done;
    }
    rewind(output);
    while (getdelim(&line, &capacity, '\0', output) != -1) {
        // A worktree whose folder was deleted but not yet pruned by git counts as gone.
        if (strncmp(line, "worktree ", 9) == 0 && access(line + 9, F_OK) == 0) {
            char *name = own_database_name(url, line + 9);
            if (name != NULL) {
                fprintf(keep, "%s\n", name);
            }
            free(name);
        }
    }
    fflush(keep);

    rewind(output);
    if (ftruncate(fileno(output), 0) != 0) {
        fprintf(stderr, "mrsk: cannot reuse temporary file: %s\n", strerror(errno));
        status = 1;
        goto done;
    }
    char *admin = url_with_database(url, "postgres");
    if (admin == NULL) {
        status = 1;
        goto done;
    }
    char *const psql[] = {
        "psql", admin, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
        "-c", "SELECT datname FROM pg_database", NULL
    };
    status = run_process_with_output(psql, false, output);
    free(admin);
    if (status != 0) {
        goto done;
    }
    rewind(output);
    while (getline(&line, &capacity, output) != -1) {
        line[strcspn(line, "\r\n")] = '\0';
        if (strncmp(line, database, length) != 0 || line[length] != '_' ||
            strchr(line, '"') != NULL || mentions(kept, line) || mentions(config, line)) {
            continue;
        }
        found++;
        if (!force) {
            printf("%s\n", line);
            continue;
        }
        char sql[512];
        snprintf(sql, sizeof(sql), "DROP DATABASE IF EXISTS \"%s\"", line);
        if (run_database_sql(url, sql) == 0) {
            printf("Removed database %s\n", line);
        } else {
            status = 1;
        }
    }
    if (found > 0 && !force) {
        fprintf(stderr, "mrsk: run 'mrsk prune --force' to drop these databases\n");
    }

done:
    if (yml != NULL) {
        fclose(yml);
    }
    if (keep != NULL) {
        fclose(keep);
    }
    if (output != NULL) {
        fclose(output);
    }
    free(kept);
    free(config);
    free(line);
    free(yml_path);
    free(url);
    free(rails);
    return status;
}

static int command_bump_migration_version(Project *project, int argc, char **argv)
{
    (void)argv;
    if (argc != 0) {
        usage(stderr);
        return 2;
    }

    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd)) == NULL) {
        fprintf(stderr, "mrsk: cannot get current directory: %s\n", strerror(errno));
        return 1;
    }

    char *url = read_env_database_url(cwd);
    char *const command[] = {
        "ruby", "-e",
        "abort 'mrsk: db/migrate not found; run from the project root' unless Dir.exist?('db/migrate')\n"
        "base = IO.popen(['git', 'merge-base', 'HEAD', ARGV[0]], &:read).strip\n"
        "abort \"mrsk: no merge base with #{ARGV[0]}\" if base.empty?\n"
        "added = IO.popen(['git', 'diff', '--name-only', '--diff-filter=A', base, '--', 'db/migrate'], &:read) +\n"
        "        IO.popen(['git', 'ls-files', '--others', '--exclude-standard', '--', 'db/migrate'], &:read)\n"
        "mine = added.split(\"\\n\").grep(%r{\\Adb/migrate/\\d{14}_.+\\.rb\\z}).uniq.sort\n"
        "abort \"mrsk: no migrations added on this branch since #{ARGV[0]}\" if mine.empty?\n"
        "newest = (Dir['db/migrate/*.rb'] - mine).map { |file| File.basename(file)[0, 14] }.grep(/\\A\\d{14}\\z/).max.to_s\n"
        "start = Time.now.utc\n"
        "start = [start, Time.utc(*newest.unpack('A4A2A2A2A2A2').map(&:to_i)) + 1].max unless newest.empty?\n"
        "renames = mine.each_with_index.map { |file, index| [file, \"db/migrate/#{(start + index).strftime('%Y%m%d%H%M%S')}_#{File.basename(file)[15..]}\"] }\n"
        "renames.reject! { |old, new| old == new }\n"
        "abort 'mrsk: migrations already carry the newest versions' if renames.empty?\n"
        "renames.each { |_, new| abort \"mrsk: #{new} already exists\" if File.exist?(new) }\n"
        "sql = renames.map { |old, new| \"UPDATE schema_migrations SET version = '#{File.basename(new)[0, 14]}' WHERE version = '#{File.basename(old)[0, 14]}'\" }.join('; ')\n"
        "url = ARGV[1].to_s\n"
        "if !url.empty? && !system('psql', url, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c', sql)\n"
        "  warn \"\\e[33mmrsk: warning: schema_migrations not updated\\e[0m\"\n"
        "end\n"
        "renames.each { |old, new| system('git', 'mv', '--', old, new, err: File::NULL) || File.rename(old, new); puts \"#{File.basename(old)} -> #{File.basename(new)}\" }\n",
        "--", project->main_branch, url != NULL ? url : "", NULL
    };
    int status = run_process(command, false);
    free(url);
    return status;
}

enum { COLUMN_STATUS, COLUMN_VERSION, COLUMN_NAME, COLUMN_COMMITTER, COLUMN_COUNT };

static char *const migration_titles[COLUMN_COUNT] = {
    " Status ", "Migration ID", "Migration Name", "Committer"
};

typedef struct {
    char *cells[COLUMN_COUNT];
    bool branch;
} MigrationRow;

static int compare_migrations(const void *left, const void *right)
{
    return strcmp(((const MigrationRow *)left)->cells[COLUMN_VERSION],
                  ((const MigrationRow *)right)->cells[COLUMN_VERSION]);
}

static MigrationRow *find_migration(MigrationRow *rows, size_t count, const char *version)
{
    MigrationRow key = {0};
    key.cells[COLUMN_VERSION] = (char *)version;
    return bsearch(&key, rows, count, sizeof(*rows), compare_migrations);
}

static MigrationRow *add_migration(MigrationRow **rows, size_t *count, const char *status,
                                   const char *version, size_t version_length)
{
    MigrationRow *grown = realloc(*rows, (*count + 1) * sizeof(**rows));
    if (grown == NULL) {
        return NULL;
    }
    *rows = grown;
    MigrationRow *row = &grown[(*count)++];
    row->branch = false;
    row->cells[COLUMN_STATUS] = strdup(status);
    row->cells[COLUMN_VERSION] = strndup(version, version_length);
    row->cells[COLUMN_NAME] = strdup("********** NO FILE **********");
    row->cells[COLUMN_COMMITTER] = strdup("");
    for (int i = 0; i < COLUMN_COUNT; i++) {
        if (row->cells[i] == NULL) {
            return NULL;
        }
    }
    return row;
}

static void print_migration_row(char *const cells[COLUMN_COUNT],
                                const size_t widths[COLUMN_COUNT], bool branch)
{
    for (int i = 0; i < COLUMN_COUNT; i++) {
        int pad = (int)(widths[i] - strlen(cells[i]));
        int left = i == COLUMN_STATUS ? pad / 2 : 0;
        int right = i == COLUMN_COUNT - 1 ? 0 : pad - left;
        bool color = branch && i == COLUMN_VERSION;
        printf("%s%*s%s%s%s%*s", i > 0 ? "  " : "", left, "", color ? "\033[33m" : "",
               cells[i], color ? "\033[0m" : "", right, "");
    }
    putchar('\n');
}

static char *git_common_dir(char *root)
{
    FILE *output = tmpfile();
    char *const command[] = {
        "git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir", NULL
    };
    char line[PATH_MAX];
    char *result = NULL;
    if (output != NULL && run_process_with_output(command, false, output) == 0) {
        rewind(output);
        if (fgets(line, sizeof(line), output) != NULL) {
            result = realpath(trim(line), NULL);
        }
    }
    if (output != NULL) {
        fclose(output);
    }
    return result;
}

static char *project_checkout(const Project *project)
{
    char root[PATH_MAX];
    char *common = realpath(project->project_root, root) != NULL ? git_common_dir(root) : NULL;
    char *dir = common != NULL ? getcwd(NULL, 0) : NULL;
    size_t common_length = common != NULL ? strlen(common) : 0;
    while (dir != NULL && strcmp(dir, root) != 0) {
        char *marker = join_path(dir, ".git");
        FILE *file = marker != NULL ? fopen(marker, "r") : NULL;
        free(marker);
        char line[PATH_MAX + 16];
        char gitdir[PATH_MAX];
        bool found = file != NULL && fgets(line, sizeof(line), file) != NULL &&
                     strncmp(line, "gitdir: ", 8) == 0 && realpath(trim(line + 8), gitdir) != NULL &&
                     strncmp(gitdir, common, common_length) == 0 && gitdir[common_length] == '/';
        if (file != NULL) {
            fclose(file);
        }
        char *slash = strrchr(dir, '/');
        if (found) {
            break;
        }
        if (slash == NULL || slash == dir) {
            free(dir);
            dir = NULL;
            break;
        }
        *slash = '\0';
    }
    free(common);
    return dir;
}

static bool schema_uses_underscores(const char *rails)
{
    char *path = join_path(rails, "db/schema.rb");
    FILE *file = path != NULL ? fopen(path, "r") : NULL;
    free(path);
    char line[4096];
    bool result = false;
    while (file != NULL && fgets(line, sizeof(line), file) != NULL) {
        char *version = strstr(line, "define(version: ");
        if (version != NULL) {
            version += 16;
            result = version[strspn(version, "0123456789")] == '_';
            break;
        }
    }
    if (file != NULL) {
        fclose(file);
    }
    return result;
}

static int command_dbst(Project *project, int argc, char **argv)
{
    bool full = argc == 1 && strcmp(argv[0], "--full") == 0;
    if (argc != (full ? 1 : 0)) {
        usage(stderr);
        return 2;
    }

    char *checkout = project_checkout(project);
    if (checkout == NULL) {
        fprintf(stderr, "mrsk: dbst must run inside a checkout of %s\n", project->project_root);
        return 1;
    }
    char *rails = rails_path(project, checkout);
    free(checkout);
    char *url = rails != NULL ? project_database_url(rails) : NULL;
    char *migrate = rails != NULL ? join_path(rails, "db/migrate") : NULL;
    FILE *output = tmpfile();
    MigrationRow *rows = NULL;
    size_t count = 0;
    char *line = NULL;
    size_t capacity = 0;
    int status = 1;
    if (url == NULL || migrate == NULL || output == NULL) {
        fprintf(stderr, url == NULL && rails != NULL ?
                "mrsk: no development database found in DATABASE_URL, .env or config/database.yml\n" :
                "mrsk: out of memory\n");
        goto done;
    }

    char *const psql[] = {
        "psql", url, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
        "-c", "SELECT version FROM schema_migrations", NULL
    };
    status = run_process_with_output(psql, false, output);
    if (status != 0) {
        goto done;
    }
    rewind(output);
    status = 1;
    ssize_t length;
    while ((length = getline(&line, &capacity, output)) != -1) {
        length = (ssize_t)strcspn(line, "\r\n");
        if (length > 0 && add_migration(&rows, &count, "up", line, (size_t)length) == NULL) {
            fprintf(stderr, "mrsk: out of memory\n");
            goto done;
        }
    }
    qsort(rows, count, sizeof(*rows), compare_migrations);

    size_t applied = count;
    DIR *dir = opendir(migrate);
    struct dirent *entry;
    while (dir != NULL && (entry = readdir(dir)) != NULL) {
        const char *file = entry->d_name;
        size_t digits = strspn(file, "0123456789");
        size_t file_length = strlen(file);
        if (digits == 0 || file[digits] != '_' || file_length < digits + 4 ||
            strcmp(file + file_length - 3, ".rb") != 0) {
            continue;
        }
        char *version = strndup(file, digits);
        MigrationRow *row = version != NULL ? find_migration(rows, applied, version) : NULL;
        if (row == NULL && version != NULL) {
            row = add_migration(&rows, &count, "down", version, digits);
        }
        free(version);
        char *name = row != NULL ? strndup(file + digits + 1, strcspn(file + digits + 1, ".")) : NULL;
        if (name == NULL) {
            fprintf(stderr, "mrsk: out of memory\n");
            closedir(dir);
            goto done;
        }
        for (char *character = name; *character != '\0'; character++) {
            if (*character == '_') {
                *character = ' ';
            }
        }
        name[0] = (char)toupper((unsigned char)name[0]);
        free(row->cells[COLUMN_NAME]);
        row->cells[COLUMN_NAME] = name;
        row->branch = true;
    }
    if (dir != NULL) {
        closedir(dir);
    }
    qsort(rows, count, sizeof(*rows), compare_migrations);

    rewind(output);
    if (ftruncate(fileno(output), 0) != 0) {
        fprintf(stderr, "mrsk: cannot reuse temporary file: %s\n", strerror(errno));
        goto done;
    }
    char *const git[] = {
        "git", "-C", rails, "log", "--no-renames", "--diff-filter=A", "--format=@%ae",
        "--name-only", "--", "db/migrate", NULL
    };
    if (run_process_with_output(git, false, output) == 0) {
        rewind(output);
        char *committer = NULL;
        while (getline(&line, &capacity, output) != -1) {
            line[strcspn(line, "\r\n")] = '\0';
            if (line[0] == '@') {
                free(committer);
                committer = strndup(line + 1, strcspn(line + 1, "@"));
                continue;
            }
            const char *file = strrchr(line, '/');
            file = file != NULL ? file + 1 : line;
            char *version = strndup(file, strspn(file, "0123456789"));
            MigrationRow *row = version != NULL ? find_migration(rows, count, version) : NULL;
            free(version);
            if (row != NULL && committer != NULL && row->cells[COLUMN_COMMITTER][0] == '\0') {
                char *copy = strdup(committer);
                if (copy != NULL) {
                    free(row->cells[COLUMN_COMMITTER]);
                    row->cells[COLUMN_COMMITTER] = copy;
                }
            }
        }
        free(committer);
    }

    rewind(output);
    if (ftruncate(fileno(output), 0) != 0) {
        fprintf(stderr, "mrsk: cannot reuse temporary file: %s\n", strerror(errno));
        goto done;
    }
    char *const upstream[] = {
        "git", "-C", rails, "ls-tree", "--name-only", "@{upstream}", "--", "db/migrate/", NULL
    };
    bool tracked = run_process_with_output(upstream, true, output) == 0;
    rewind(output);
    while (tracked && getline(&line, &capacity, output) != -1) {
        const char *file = strrchr(line, '/');
        file = file != NULL ? file + 1 : line;
        char *version = strndup(file, strspn(file, "0123456789"));
        MigrationRow *row = version != NULL ? find_migration(rows, count, version) : NULL;
        free(version);
        if (row != NULL) {
            row->branch = false;
        }
    }
    for (size_t j = 0; !tracked && j < count; j++) {
        rows[j].branch = false;
    }

    if (schema_uses_underscores(rails)) {
        for (size_t j = 0; j < count; j++) {
            char *version = rows[j].cells[COLUMN_VERSION];
            char *spaced = malloc(18);
            if (strlen(version) != 14 || strspn(version, "0123456789") != 14 || spaced == NULL) {
                free(spaced);
                continue;
            }
            snprintf(spaced, 18, "%.4s_%.2s_%.2s_%.6s", version, version + 4, version + 6,
                     version + 8);
            free(version);
            rows[j].cells[COLUMN_VERSION] = spaced;
        }
    }

    size_t first = full || count <= 20 ? 0 : count - 20;
    size_t widths[COLUMN_COUNT];
    size_t total = 2 * (COLUMN_COUNT - 1);
    for (int i = 0; i < COLUMN_COUNT; i++) {
        widths[i] = strlen(migration_titles[i]);
        for (size_t j = first; j < count; j++) {
            size_t width = strlen(rows[j].cells[i]);
            widths[i] = width > widths[i] ? width : widths[i];
        }
        total += widths[i];
    }
    print_migration_row(migration_titles, widths, false);
    for (size_t i = 0; i < total; i++) {
        putchar('-');
    }
    putchar('\n');
    for (size_t j = first; j < count; j++) {
        print_migration_row(rows[j].cells, widths, rows[j].branch);
    }
    status = 0;

done:
    for (size_t j = 0; j < count; j++) {
        for (int i = 0; i < COLUMN_COUNT; i++) {
            free(rows[j].cells[i]);
        }
    }
    free(rows);
    free(line);
    if (output != NULL) {
        fclose(output);
    }
    free(migrate);
    free(url);
    free(rails);
    return status;
}

static int command_updater(Project *project, int argc, char **argv)
{
    if (argc != 1) {
        usage(stderr);
        return 2;
    }
    char *const command[] = {
        "worktree-target-branch-updater", argv[0], project->project_root,
        project->main_branch, NULL
    };
    return run_process(command, false);
}

static const CommandEntry *find_command(const CommandEntry *commands, size_t command_count,
                                        const char *name)
{
    for (size_t i = 0; i < command_count; i++) {
        if (strcmp(name, commands[i].name) == 0) {
            return &commands[i];
        }
    }
    return NULL;
}

static Project *find_project(Config *config, const char *name)
{
    if (name == NULL) {
        if (config->project_count == 1) {
            return &config->projects[0];
        }

        char cwd[PATH_MAX];
        if (getcwd(cwd, sizeof(cwd)) == NULL) {
            fprintf(stderr, "mrsk: cannot get current directory: %s\n", strerror(errno));
            return NULL;
        }
        Project *match = NULL;
        size_t match_length = 0;
        bool ambiguous = false;
        for (size_t i = 0; i < config->project_count; i++) {
            char root[PATH_MAX];
            if (realpath(config->projects[i].project_root, root) == NULL) {
                continue;
            }
            const char *slash = strrchr(root, '/');
            if (slash == NULL || slash == root) {
                continue;
            }
            size_t length = (size_t)(slash - root);
            if (strncmp(cwd, root, length) != 0 ||
                (cwd[length] != '\0' && cwd[length] != '/')) {
                continue;
            }
            if (length > match_length) {
                match = &config->projects[i];
                match_length = length;
                ambiguous = false;
            } else if (length == match_length) {
                ambiguous = true;
            }
        }
        if (match != NULL) {
            if (!ambiguous) {
                return match;
            }
            fprintf(stderr, "mrsk: multiple projects match the current directory; specify one\n");
            usage(stderr);
            return NULL;
        }
        for (size_t i = 0; i < config->project_count; i++) {
            if (config->projects[i].default_project) {
                return &config->projects[i];
            }
        }
        fprintf(stderr, "mrsk: multiple projects configured; specify one\n");
        usage(stderr);
        return NULL;
    }

    for (size_t i = 0; i < config->project_count; i++) {
        if (config->projects[i].name != NULL && strcmp(name, config->projects[i].name) == 0) {
            return &config->projects[i];
        }
    }
    fprintf(stderr, "mrsk: unknown project '%s'\n", name);
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc < 2 || strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
        usage(argc < 2 ? stderr : stdout);
        return argc < 2 ? 2 : 0;
    }
    if (argc == 4 && strcmp(argv[1], "__worktree-target-branch-updater-run") == 0) {
        char *const command[] = {
            "worktree-target-branch-updater", "run", argv[2], argv[3], NULL
        };
        return run_process(command, false);
    }
    if (strcmp(argv[1], "configure") == 0) {
        return command_configure(argc - 2);
    }
    if (strcmp(argv[1], "clone") == 0) {
        return command_clone(argc - 2, argv + 2);
    }
    if (strcmp(argv[1], "review") == 0) {
        return command_review(argv);
    }
    if (strcmp(argv[1], "rails-schema-confl") == 0) {
        return command_rails_schema_conflict(argc - 2);
    }
    if (strcmp(argv[1], "shell-init") == 0) {
        return command_shell_init(argc - 2);
    }
    if (strcmp(argv[1], "redmine") == 0) {
        Config config = {0};
        if (load_config(&config, false) != 0) {
            free_config(&config);
            return 1;
        }
        int status = command_redmine(&config, argc - 2);
        free_config(&config);
        return status;
    }

    static const CommandEntry commands[] = {
        {"new", command_new},
        {"open", command_open},
        {"remove", command_remove},
        {"delete_all", command_delete_all},
        {"updater", command_updater},
        {"daemon", command_updater},
        {"list", command_list},
        {"bump-migration-version", command_bump_migration_version},
        {"dbst", command_dbst},
        {"prune", command_prune},
    };
    const size_t command_count = sizeof(commands) / sizeof(commands[0]);
    const CommandEntry shortcut = {NULL, command_switch};

    const char *project_name = NULL;
    int command_index = 1;
    const CommandEntry *selected = find_command(commands, command_count, argv[command_index]);
    if (selected == NULL) {
        bool shortcut_args =
            (argc == 2 && shortcut_name(argv[1])) ||
            (argc == 3 && ((shortcut_name(argv[1]) && database_flag(argv[2])) ||
                           (database_flag(argv[1]) && shortcut_name(argv[2]))));
        if (shortcut_args) {
            selected = &shortcut;
            command_index = 0;
        } else {
            project_name = argv[1];
            command_index = 2;
            if (argc > command_index) {
                selected = find_command(commands, command_count, argv[command_index]);
            }
            if (selected == NULL) {
                fprintf(stderr, "mrsk: unknown command '%s'\n",
                        argc > command_index ? argv[command_index] : argv[1]);
                usage(stderr);
                return 2;
            }
        }
    }

    Config config = {0};
    if (load_config(&config, false) != 0) {
        free_config(&config);
        return 1;
    }
    Project *project = find_project(&config, project_name);
    if (project == NULL) {
        free_config(&config);
        return 2;
    }
    int status = selected->run(project, argc - command_index - 1, argv + command_index + 1);
    free_config(&config);
    return status;
}
