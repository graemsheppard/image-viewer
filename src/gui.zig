const std = @import("std");
const glfw = @cImport({
    @cInclude("glfw3.h");
});
const gl = @cImport({
    @cInclude("glad/glad.h");
});
const bmp = @import("bitmap.zig");

pub const Window = glfw.GLFWwindow;

pub fn testWindow(bitmap: bmp.Bitmap) !void {
    if (glfw.glfwInit() == 0) {
        std.debug.print("Failed to initialize GLFW.\n", .{});
        std.process.exit(1);
    }
    defer glfw.glfwTerminate();
    
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_PROFILE, glfw.GLFW_OPENGL_CORE_PROFILE);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_FORWARD_COMPAT, glfw.GL_TRUE);
    glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GL_TRUE);

    const window = glfw.glfwCreateWindow(256, 256, "HELLO", null, null);
    
    if (window == null) {
        std.debug.print("GLFW could not create the window.\n", .{});
        std.process.exit(1);
    }

    defer glfw.glfwDestroyWindow(window);
    defer glfw.glfwTerminate();
    glfw.glfwMakeContextCurrent(window);
    glfw.glfwSwapInterval(1);

    if (gl.gladLoadGLLoader(@ptrCast(&glfw.glfwGetProcAddress)) == 0) {
        std.debug.print("Could not initialize OpenGL.\n", .{});
        std.process.exit(1);
    }

    var texture_id: gl.GLuint = 0;
    defer gl.glDeleteTextures(1, &texture_id);
    
    gl.glGenTextures(1, &texture_id);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, texture_id);

    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_REPEAT);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_REPEAT);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);

    const dimensions = bitmap.dib_header.getDimensions();

    gl.glTexImage2D(
        gl.GL_TEXTURE_2D,
        0,
        gl.GL_RGB,
        dimensions.x,
        dimensions.y,
        0,
        gl.GL_BGR,
        gl.GL_UNSIGNED_BYTE,
        @ptrCast(bitmap.pixels)
    );
    

    const v_shader_id: gl.GLuint = gl.glCreateShader(gl.GL_VERTEX_SHADER);
    const f_shader_id: gl.GLuint = gl.glCreateShader(gl.GL_FRAGMENT_SHADER);
    defer gl.glDeleteShader(v_shader_id);
    defer gl.glDeleteShader(f_shader_id);

    const vertex_shader_ptr: [*]const u8 = vt_shader;
    const fragment_shader_ptr: [*]const u8 = ft_shader;
    gl.glShaderSource(v_shader_id, 1, &vertex_shader_ptr, null);
    gl.glShaderSource(f_shader_id, 1, &fragment_shader_ptr, null);
    
    gl.glCompileShader(v_shader_id);

    var compileResult: i32 = 0;
    gl.glGetShaderiv(v_shader_id, gl.GL_COMPILE_STATUS, &compileResult);
    if (compileResult == gl.GL_FALSE) {
        var length: i32 = 0;
        gl.glGetShaderiv(v_shader_id, gl.GL_INFO_LOG_LENGTH, &length);
        const message = try std.heap.page_allocator.alloc(u8, @intCast(@abs(length)));
        defer std.heap.page_allocator.free(message);
        gl.glGetShaderInfoLog(v_shader_id, @bitCast(length), &length, @ptrCast(message));
        std.debug.print("Failed to compile shader 1: \n{s}\n", .{message});
    }
    gl.glCompileShader(f_shader_id);

    compileResult = 0;
    gl.glGetShaderiv(f_shader_id, gl.GL_COMPILE_STATUS, &compileResult);
    if (compileResult == gl.GL_FALSE) {
        var length: i32 = 0;
        gl.glGetShaderiv(f_shader_id, gl.GL_INFO_LOG_LENGTH, &length);
        const message = try std.heap.page_allocator.alloc(u8, @intCast(@abs(length)));
        defer std.heap.page_allocator.free(message);
        gl.glGetShaderInfoLog(f_shader_id, @bitCast(length), &length, @ptrCast(message));
        std.debug.print("Failed to compile shader 2: \n{s}\n", .{message});
    }

    const shader_program = gl.glCreateProgram();

    gl.glAttachShader(shader_program, v_shader_id);
    gl.glAttachShader(shader_program, f_shader_id);

    gl.glLinkProgram(shader_program);
    gl.glValidateProgram(shader_program);

    const positions: [16]f32 = [_]f32{
        -1.0, -1.0,  0.0,  0.0,
        -1.0,  1.0,  0.0,  1.0,
         1.0,  1.0,  1.0,  1.0,
         1.0, -1.0,  1.0,  0.0
    };

    const indices: [6]u32 = [_]u32{
        0, 1, 2, 2, 3, 0
    };

    var vao: u32 = 0;
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);

    var buffer: u32 = 0;
    gl.glGenBuffers(1, &buffer);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, buffer);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, positions.len * @sizeOf(f32), &positions, gl.GL_STATIC_DRAW);

    var index_buffer: u32 = 0;
    gl.glGenBuffers(1, &index_buffer);
    gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, index_buffer);
    gl.glBufferData(gl.GL_ELEMENT_ARRAY_BUFFER, indices.len * @sizeOf(u32), &indices, gl.GL_STATIC_DRAW);
   
    gl.glEnableVertexAttribArray(0);
    gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(0));
    gl.glEnableVertexAttribArray(1);
    gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(8));

    gl.glUseProgram(shader_program);

    const sampler_loc = gl.glGetUniformLocation(shader_program, "u_Texture");
    std.debug.print("{}!\n", .{sampler_loc});
    gl.glUniform1i(sampler_loc, 0);

    while(glfw.glfwWindowShouldClose(window) == 0) {
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        gl.glDrawElements(gl.GL_TRIANGLES, indices.len, gl.GL_UNSIGNED_INT, null);
        glfw.glfwWaitEvents();
        glfw.glfwSwapBuffers(window);
    }
}


const vt_shader =
\\  #version 330 core
\\  layout (location = 0) in vec2 position;
\\  layout (location = 1) in vec2 texCoord;
\\  out vec2 v_TexCoord;
\\  void main() {
\\      gl_Position = vec4(position, 0.0, 1.0);
\\      v_TexCoord = texCoord;
\\  }
;

const ft_shader =
\\  #version 330 core
\\  uniform vec4 u_Color;
\\  uniform sampler2D u_Texture;
\\  in vec2 v_TexCoord;
\\  layout (location = 0) out vec4 color;
\\  void main() {
\\      color = texture(u_Texture, v_TexCoord);
\\  }
;
