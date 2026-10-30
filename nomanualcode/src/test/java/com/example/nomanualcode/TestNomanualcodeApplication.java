package com.example.nomanualcode;

import org.springframework.boot.SpringApplication;

public class TestNomanualcodeApplication {

    public static void main(String[] args) {
        SpringApplication.from(NomanualcodeApplication::main).with(TestcontainersConfiguration.class).run(args);
    }

}
