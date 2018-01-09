#include <stdlib.h>

typedef void(*_PVFV)(void);

typedef struct atexit_node
{
    struct atexit_node* next;
    _PVFV pfn;
} atexit_node;

static atexit_node* atexit_list;

int atexit(_PVFV pfn)
{
    atexit_node* node = malloc(sizeof(atexit_node));
    if(!node)
        return -1;
    // TODO: not thread safe
    node->pfn = pfn;
    node->next = atexit_list;
    atexit_list = node;
    return 0;
}

void term_atexit()
{
    while(atexit_list)
    {
        atexit_node* n = atexit_list;
        atexit_list = n->next;
        (*(n->pfn))();
        free(n);
    }
}
