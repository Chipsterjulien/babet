#include "gui_gtk_loader.hpp"

#include <iostream>
#include <string>
#include <string_view>

int main(int argc, char **argv)
{
    if (argc != 2)
        return 64;

    const std::string_view mode(argv[1]);
    std::string error;
    if (mode == "load")
    {
        if (babet_gui::detail::gtk4_load(error))
        {
            std::cout << "LOAD_OK\n";
            return 0;
        }
        std::cout << "LOAD_FAIL " << error << "\n";
        return 2;
    }
    if (mode == "init")
    {
        if (babet_gui::detail::gtk4_initialize(error))
        {
            std::cout << "INIT_OK\n";
            return 0;
        }
        std::cout << "INIT_FAIL " << error << "\n";
        return 3;
    }
    if (mode == "load-twice")
    {
        std::string first_error;
        if (babet_gui::detail::gtk4_load(first_error))
            return 5;

        std::string second_error;
        if (babet_gui::detail::gtk4_load(second_error))
            return 6;

        if (first_error != second_error)
            return 7;

        std::cout << "LOAD_TWICE_FAIL " << second_error << "\n";
        return 4;
    }
    return 64;
}
