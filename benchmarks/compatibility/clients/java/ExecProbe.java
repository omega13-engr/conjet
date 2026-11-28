import com.fasterxml.jackson.databind.ObjectMapper;
import com.github.dockerjava.api.async.ResultCallback;
import com.github.dockerjava.api.model.Frame;
import com.github.dockerjava.core.DefaultDockerClientConfig;
import com.github.dockerjava.core.DockerClientImpl;
import com.github.dockerjava.httpclient5.ApacheDockerHttpClient;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Map;
import java.util.concurrent.TimeUnit;

class ExecProbe {
    public static void main(String[] args) throws Exception {
        var config = DefaultDockerClientConfig.createDefaultConfigBuilder()
            .withDockerHost(args[0])
            .withDockerConfig(args[1])
            .withApiVersion("1.44")
            .build();
        var transport = new ApacheDockerHttpClient.Builder()
            .dockerHost(config.getDockerHost())
            .connectionTimeout(Duration.ofSeconds(5))
            .responseTimeout(Duration.ofSeconds(8))
            .build();
        var results = new ArrayList<Map<String, Object>>();
        try (var client = DockerClientImpl.getInstance(config, transport)) {
            for (int i = 3; i < args.length; i++) {
                String id = client.execCreateCmd(args[2])
                    .withAttachStdout(true).withAttachStderr(true).withTty(false)
                    .withCmd("/bin/sh", "-c", args[i]).exec().getId();
                var stdout = new ByteArrayOutputStream();
                var stderr = new ByteArrayOutputStream();
                try (var callback = new ResultCallback.Adapter<Frame>() {
                    @Override
                    public void onNext(Frame frame) {
                        switch (frame.getStreamType()) {
                            case STDOUT: stdout.writeBytes(frame.getPayload()); break;
                            case STDERR: stderr.writeBytes(frame.getPayload()); break;
                            default: throw new IllegalStateException("Unexpected stream " + frame.getStreamType());
                        }
                    }
                }) {
                    if (!client.execStartCmd(id).withDetach(false).withTty(false)
                            .exec(callback).awaitCompletion(8, TimeUnit.SECONDS)) {
                        throw new IllegalStateException("Exec stream did not complete");
                    }
                }

                var status = client.inspectExecCmd(id).exec();
                if (!Boolean.FALSE.equals(status.isRunning()) || status.getExitCodeLong() == null) {
                    throw new IllegalStateException("Exec stream ended before a terminal exit status");
                }
                results.add(Map.of("exit", status.getExitCodeLong(),
                    "stdout", stdout.toString(StandardCharsets.UTF_8),
                    "stderr", stderr.toString(StandardCharsets.UTF_8)));
            }
        }
        System.out.println(new ObjectMapper().writeValueAsString(results));
    }
}
