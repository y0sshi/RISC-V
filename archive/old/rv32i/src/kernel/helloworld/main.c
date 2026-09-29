#define UARTADDR_VIRT 0x10000000;

void print_uart(const char* str_in);

int main(void) {
    print_uart("hello, world!!\n");

    return 0;
}

void print_uart(const char* str_in) {
    volatile unsigned int* const UART0DR = (unsigned int *)UARTADDR_VIRT; 
    while (*str_in != '\0') {
        *UART0DR = (unsigned int)(*str_in);
        ++str_in;
    }
}
