<?php

namespace WebSC\SampleBundle\Tests\PHPUnit;

use Guzzle\Http\Client;

class RoutingTest extends WebTestCase
{
    /**
     * NB: this test is executed by talking to the WEB container - so we use Guzzle instead of the default SF http client
     * @dataProvider urlProvider
     */
    public function testRouteIsAvailable($url)
    {
        $client = new Client();
        $request = $client->get($this->getHostName() . $url);
        try {
            $response = $client->send($request);
            $this->assertEquals(200, $response->getStatusCode());
        } catch (\Guzzle\Http\Exception\ClientErrorResponseException $e) {
            $this->fail($e->getMessage());
        }
    }

    public function urlProvider()
    {
        return array(
            array('/'),
            // ...
        );
    }
}
