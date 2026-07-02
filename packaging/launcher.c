#include <Python.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>


static int resource_path(char *output, size_t output_size) {
    char executable[PATH_MAX];
    uint32_t executable_size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &executable_size) != 0) {
        return -1;
    }

    char resolved[PATH_MAX];
    if (realpath(executable, resolved) == NULL) {
        return -1;
    }

    char executable_copy[PATH_MAX];
    char macos_directory[PATH_MAX];
    snprintf(executable_copy, sizeof(executable_copy), "%s", resolved);
    snprintf(
        macos_directory,
        sizeof(macos_directory),
        "%s",
        dirname(executable_copy)
    );
    snprintf(output, output_size, "%s/../Resources", macos_directory);
    return 0;
}


static void redirect_logs(void) {
    const char *home = getenv("HOME");
    if (home == NULL) {
        return;
    }

    char log_directory[PATH_MAX];
    char log_file[PATH_MAX];
    snprintf(log_directory, sizeof(log_directory), "%s/Library/Logs/Whisper Clipboard", home);
    mkdir(log_directory, 0755);
    snprintf(log_file, sizeof(log_file), "%s/app.log", log_directory);

    freopen(log_file, "a", stdout);
    freopen(log_file, "a", stderr);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}


int main(void) {
    char resources[PATH_MAX];
    char python_home[PATH_MAX];
    char app_path[PATH_MAX];
    char config_path[PATH_MAX];

    if (resource_path(resources, sizeof(resources)) != 0) {
        return 1;
    }

    redirect_logs();
    snprintf(python_home, sizeof(python_home), "%s/runtime", resources);
    snprintf(app_path, sizeof(app_path), "%s/app", resources);
    snprintf(config_path, sizeof(config_path), "%s/config.toml", resources);

    setenv("HF_HUB_OFFLINE", "1", 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    setenv("PYTHONHOME", python_home, 1);
    setenv("PYTHONPATH", app_path, 1);
    setenv("WHISPER_CLIPBOARD_CONFIG", config_path, 1);
    chdir(resources);

    char *python_argv[] = {
        "WhisperClipboard",
        "-m",
        "whisper_clipboard",
        "--show-window",
        NULL,
    };
    return Py_BytesMain(4, python_argv);
}
