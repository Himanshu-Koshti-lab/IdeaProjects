package com.example.nomanualcode.logging;

import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.aspectj.lang.reflect.MethodSignature;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.aop.framework.AopProxyUtils;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Component;

import java.util.Collection;
import java.util.StringJoiner;

/**
 * Logs every REST controller call (arguments, outcome, duration) at INFO, and every repository call
 * at DEBUG. Calls slower than {@code app.logging.slow-threshold-ms} are logged at WARN.
 * Request bodies are logged by type only, so personal data never reaches the logs.
 */
@Aspect
@Component
public class LoggingAspect {

    private final long slowThresholdMs;

    public LoggingAspect(@Value("${app.logging.slow-threshold-ms:500}") long slowThresholdMs) {
        this.slowThresholdMs = slowThresholdMs;
    }

    @Around("within(com.example.nomanualcode..*) && @within(org.springframework.web.bind.annotation.RestController)")
    public Object logController(ProceedingJoinPoint joinPoint) throws Throwable {
        Class<?> type = joinPoint.getSignature().getDeclaringType();
        return log(joinPoint, LoggerFactory.getLogger(type), type.getSimpleName(), false);
    }

    @Around("execution(* org.springframework.data.repository.Repository+.*(..))")
    public Object logRepository(ProceedingJoinPoint joinPoint) throws Throwable {
        // Spring Data repositories are JDK proxies; their first interface is the app's repository type.
        Class<?>[] interfaces = AopProxyUtils.proxiedUserInterfaces(joinPoint.getThis());
        Class<?> type = interfaces.length > 0 ? interfaces[0] : joinPoint.getSignature().getDeclaringType();
        return log(joinPoint, LoggerFactory.getLogger(type), type.getSimpleName(), true);
    }

    private Object log(ProceedingJoinPoint joinPoint, Logger logger, String typeName, boolean debug)
            throws Throwable {
        if (debug && !logger.isDebugEnabled()) {
            return joinPoint.proceed();
        }
        String call = typeName + "." + joinPoint.getSignature().getName() + "(" + formatArgs(joinPoint) + ")";
        long start = System.nanoTime();
        try {
            Object result = joinPoint.proceed();
            long elapsedMs = (System.nanoTime() - start) / 1_000_000;
            boolean isVoid = ((MethodSignature) joinPoint.getSignature()).getReturnType() == void.class;
            String outcome = isVoid ? "done" : formatResult(result);
            String message = "{} -> {} [{} ms]";
            if (elapsedMs > slowThresholdMs) {
                logger.warn("SLOW " + message, call, outcome, elapsedMs);
            } else if (debug) {
                logger.debug(message, call, outcome, elapsedMs);
            } else {
                logger.info(message, call, outcome, elapsedMs);
            }
            return result;
        } catch (Throwable ex) {
            long elapsedMs = (System.nanoTime() - start) / 1_000_000;
            String message = "{} -> threw {}: {} [{} ms]";
            // Only the outermost (controller) layer logs at ERROR, so one failure produces one ERROR line.
            if (debug) {
                logger.debug(message, call, ex.getClass().getSimpleName(), firstLine(ex.getMessage()), elapsedMs);
            } else {
                logger.error(message, call, ex.getClass().getSimpleName(), firstLine(ex.getMessage()), elapsedMs);
            }
            throw ex;
        }
    }

    private static String firstLine(String message) {
        if (message == null) {
            return "";
        }
        int newline = message.indexOf('\n');
        return newline < 0 ? message : message.substring(0, newline).strip() + " ...";
    }

    private static String formatArgs(ProceedingJoinPoint joinPoint) {
        String[] names = ((MethodSignature) joinPoint.getSignature()).getParameterNames();
        Object[] args = joinPoint.getArgs();
        StringJoiner joiner = new StringJoiner(", ");
        for (int i = 0; i < args.length; i++) {
            String value = formatValue(args[i]);
            joiner.add(names != null ? names[i] + "=" + value : value);
        }
        return joiner.toString();
    }

    private static String formatResult(Object result) {
        if (result instanceof ResponseEntity<?> response) {
            return response.getStatusCode() + (response.hasBody() ? " " + formatValue(response.getBody()) : "");
        }
        return formatValue(result);
    }

    private static String formatValue(Object value) {
        if (value == null || value instanceof Number || value instanceof Boolean || value instanceof Enum<?>) {
            return String.valueOf(value);
        }
        if (value instanceof CharSequence text) {
            return "\"" + text + "\"";
        }
        if (value instanceof Collection<?> collection) {
            return collection.size() + (collection.size() == 1 ? " item" : " items");
        }
        if (value instanceof java.util.Optional<?> optional) {
            return optional.isPresent() ? "Optional[" + formatValue(optional.get()) + "]" : "Optional.empty";
        }
        return value.getClass().getSimpleName();
    }

}
