/* Native adapter probe only: the real compiler tests formatting semantics. */
#include "../compiler/ada/src/platform/landin_format_replace.c"
int main(int argc, char **argv) {
    if (argc != 3 || strcmp(argv[1], "fmt") != 0) return 2;
    FILE *input = fopen(argv[2], "rb");
    if (!input) return 2;
    if (fseek(input, 0, SEEK_END) != 0) return 2;
    long length = ftell(input);
    if (length < 2 || fseek(input, 0, SEEK_SET) != 0) return 2;
    char *bytes = malloc((size_t)length);
    if (!bytes || fread(bytes, 1, (size_t)length, input) != (size_t)length) return 2;
    fclose(input);
    /* The test source begins with two excess spaces. */
    int result = landin_replace_existing_file(argv[2], bytes + 2, (size_t)length - 2);
    free(bytes);
    if (result) { fputs("error[L0005]: replacement refused\n", stderr); return 1; }
    return 0;
}
